#!/usr/bin/env python3
"""Pot waitlist capture backend (moneycircle.finance).

POST /waitlist  -> append signup to CSV, email confirmation to submitter +
notification to owner, return JSON. CORS-restricted to the live frontend.

Credentials (GMAIL_ADDRESS / GMAIL_APP_PASSWORD) load from the central
~/server/.credentials.env at startup. Per the box's hard rule this service
talks only to Gmail SMTP — it never calls any LLM/API.
"""
import csv
import fcntl
import os
import re
import smtplib
import sys
import threading
from datetime import datetime, timezone
from email.mime.text import MIMEText
from pathlib import Path

from flask import Flask, jsonify, request

# --- config ---------------------------------------------------------------
PORT = int(os.environ.get("POT_WAITLIST_PORT", "5773"))
BASE_DIR = Path(__file__).resolve().parent
CSV_DIR = BASE_DIR  # signups.csv lives alongside server.py in waitlist/
CSV_PATH = CSV_DIR / "signups.csv"
CREDENTIALS_ENV = Path.home() / "server" / ".credentials.env"

OWNER_EMAIL = "laurens.whipple@gmail.com"
ALLOWED_ORIGIN = "https://moneycircle.finance"
ALLOWED_GOALS = {"medical bill", "used car", "emergency fund", "down payment", "other"}

# A pragmatic, deliberately-not-RFC-5322-perfect email check: one @, a dot in
# the domain, no whitespace. Good enough to reject obvious garbage without
# bouncing valid addresses.
EMAIL_RE = re.compile(r"^[^@\s]+@[^@\s]+\.[^@\s]+$")

CONFIRM_SUBJECT = "You're on the Pot waitlist"
CONFIRM_BODY = """Hey —

You're on the list. When the first circles form, you'll hear from us first.

In the meantime: the protocol is open source at github.com/pot-protocol/pot.
Read how it works, share it with someone who needs it.

—Pot
moneycircle.finance
"""

# Serialize SMTP sends so two concurrent requests don't race on one
# connection; cheap given the expected signup volume.
_smtp_lock = threading.Lock()


def load_credentials() -> None:
    """Parse the central .credentials.env into os.environ (no extra deps).

    Minimal KEY=VALUE parser: skips blanks/comments, strips an optional
    `export ` prefix and surrounding quotes. Does not overwrite values already
    present in the environment (so systemd EnvironmentFile / shell exports win).
    """
    if not CREDENTIALS_ENV.exists():
        return
    for raw in CREDENTIALS_ENV.read_text(encoding="utf-8", errors="replace").splitlines():
        line = raw.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        if line.startswith("export "):
            line = line[len("export "):]
        key, _, value = line.partition("=")
        key = key.strip()
        value = value.strip().strip('"').strip("'")
        if key and key not in os.environ:
            os.environ[key] = value


load_credentials()
GMAIL_ADDRESS = os.environ.get("GMAIL_ADDRESS", OWNER_EMAIL)
GMAIL_APP_PASSWORD = os.environ.get("GMAIL_APP_PASSWORD", "")

app = Flask(__name__)


# --- CORS -----------------------------------------------------------------
def _cors_headers(resp):
    """Attach CORS headers for the live frontend origin only."""
    origin = request.headers.get("Origin", "")
    if origin == ALLOWED_ORIGIN:
        resp.headers["Access-Control-Allow-Origin"] = ALLOWED_ORIGIN
        resp.headers["Vary"] = "Origin"
        resp.headers["Access-Control-Allow-Methods"] = "POST, OPTIONS"
        resp.headers["Access-Control-Allow-Headers"] = "Content-Type"
        resp.headers["Access-Control-Max-Age"] = "86400"
    return resp


@app.after_request
def add_cors(resp):
    return _cors_headers(resp)


# --- persistence ----------------------------------------------------------
def append_signup(email: str, goal: str) -> int:
    """Append one row under flock; return the total signup count (data rows)."""
    CSV_DIR.mkdir(parents=True, exist_ok=True)
    timestamp = datetime.now(timezone.utc).isoformat()
    # Open in a+ so the file is created if missing and we can both write and
    # re-read for the count, all while holding a single exclusive lock.
    with open(CSV_PATH, "a+", newline="", encoding="utf-8") as fh:
        fcntl.flock(fh.fileno(), fcntl.LOCK_EX)
        try:
            fh.seek(0, os.SEEK_END)
            need_header = fh.tell() == 0
            writer = csv.writer(fh)
            if need_header:
                writer.writerow(["timestamp", "email", "goal"])
            writer.writerow([timestamp, email, goal])
            fh.flush()
            os.fsync(fh.fileno())
            # Count data rows (total file rows minus the header).
            fh.seek(0)
            count = max(sum(1 for _ in fh) - 1, 0)
        finally:
            fcntl.flock(fh.fileno(), fcntl.LOCK_UN)
    return count


# --- email ----------------------------------------------------------------
def _send(to_addr: str, subject: str, body: str, reply_to: str | None = None) -> None:
    msg = MIMEText(body, "plain", "utf-8")
    msg["From"] = GMAIL_ADDRESS
    msg["To"] = to_addr
    msg["Subject"] = subject
    if reply_to:
        msg["Reply-To"] = reply_to
    with _smtp_lock:
        with smtplib.SMTP_SSL("smtp.gmail.com", 465, timeout=30) as server:
            server.login(GMAIL_ADDRESS, GMAIL_APP_PASSWORD)
            server.sendmail(GMAIL_ADDRESS, [to_addr], msg.as_string())


def send_confirmation(email: str) -> None:
    _send(email, CONFIRM_SUBJECT, CONFIRM_BODY, reply_to=OWNER_EMAIL)


def send_owner_notification(email: str, goal: str, count: int) -> None:
    goal_str = goal if goal else "not specified"
    body = (
        f"{email} joined the waitlist. Goal: {goal_str}. "
        f"Total signups: {count}."
    )
    _send(OWNER_EMAIL, f"New Pot waitlist signup: {email}", body)


# --- request parsing ------------------------------------------------------
def extract_payload():
    """Return (email, goal) from JSON or form-encoded body."""
    data = request.get_json(silent=True)
    if not isinstance(data, dict):
        data = request.form
    email = (data.get("email") or "").strip()
    goal = (data.get("goal") or "").strip()
    return email, goal


# --- routes ---------------------------------------------------------------
@app.route("/waitlist", methods=["POST", "OPTIONS"])
def waitlist():
    if request.method == "OPTIONS":
        # CORS preflight; headers added by after_request.
        return ("", 204)

    email, goal = extract_payload()

    if not email:
        return jsonify(ok=False, error="Email is required."), 400
    if len(email) > 254 or not EMAIL_RE.match(email):
        return jsonify(ok=False, error="Please enter a valid email address."), 400
    # Accept any goal the dropdown might send (including empties/unknowns) but
    # cap length so the CSV/email can't be stuffed.
    if len(goal) > 100:
        goal = goal[:100]
    if goal and goal not in ALLOWED_GOALS:
        # Keep the value (forward-compatible with new dropdown options) — just
        # don't let it be anything wild beyond the length cap above.
        pass

    try:
        count = append_signup(email, goal)
    except OSError as exc:
        app.logger.exception("Failed to persist signup")
        return jsonify(ok=False, error="Could not save your signup. Try again."), 500

    # Persistence is the source of truth; email is best-effort. A submitter who
    # is saved but whose mail bounced should still see success — we log and move
    # on rather than 500 on an SMTP hiccup.
    try:
        send_confirmation(email)
    except Exception:
        app.logger.exception("Confirmation email failed for %s", email)
    try:
        send_owner_notification(email, goal, count)
    except Exception:
        app.logger.exception("Owner notification email failed for %s", email)

    return jsonify(ok=True)


@app.route("/health", methods=["GET"])
def health():
    return jsonify(ok=True, service="pot-waitlist", port=PORT)


if __name__ == "__main__":
    if not GMAIL_APP_PASSWORD:
        print("WARNING: GMAIL_APP_PASSWORD not set; emails will fail.", file=sys.stderr)
    app.run(host="127.0.0.1", port=PORT)
