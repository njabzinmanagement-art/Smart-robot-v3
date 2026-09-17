from dotenv import load_dotenv
load_dotenv()
import os, time, secrets
from typing import Optional
from fastapi import FastAPI, HTTPException, Header
from pydantic import BaseModel
import jwt

app = FastAPI(title="NJABZIN Smart Trader Bridge", version="2.0")

JWT_SECRET = os.getenv("JWT_SECRET", "DEV_ONLY_CHANGE_ME")
ADMIN_USERNAME = os.getenv("ADMIN_USERNAME", "njabzin")
ADMIN_PASSWORD = os.getenv("ADMIN_PASSWORD", "CHANGE_ME")
DEVICE_TOKEN = os.getenv("DEVICE_TOKEN", "DEV_DEVICE_TOKEN")

# Demo in-memory state. For production, replace with PostgreSQL/Redis.
state = {
    "running": False,
    "risk": 0.5,
    "max_trades": 5,
    "daily_loss": 2.0,
    "balance": 0.0,
    "equity": 0.0,
    "profit": 0.0,
    "symbol": "",
    "position": "NONE",
    "position_volume": 0.0,
    "last_signal": "WAITING",
    "last_trade": "",
    "last_update": 0,
}
pending_command = {"id": 0, "running": False, "risk": 0.5, "max_trades": 5, "daily_loss": 2.0}

class Login(BaseModel):
    username: str
    password: str

class Settings(BaseModel):
    running: Optional[bool] = None
    risk: Optional[float] = None
    max_trades: Optional[int] = None
    daily_loss: Optional[float] = None

class EAStatus(BaseModel):
    balance: float = 0
    equity: float = 0
    profit: float = 0
    symbol: str = ""
    position: str = "NONE"
    position_volume: float = 0
    last_signal: str = "WAITING"
    last_trade: str = ""
    running: bool = False

def issue_token(username: str):
    now = int(time.time())
    return jwt.encode(
        {"sub": username, "iat": now, "exp": now + 3600},
        JWT_SECRET,
        algorithm="HS256"
    )

def require_user(authorization: Optional[str]):
    if not authorization or not authorization.startswith("Bearer "):
        raise HTTPException(401, "Missing authentication")
    token = authorization[7:]
    try:
        jwt.decode(token, JWT_SECRET, algorithms=["HS256"])
    except jwt.PyJWTError:
        raise HTTPException(401, "Invalid or expired token")

def require_device(token: Optional[str]):
    if not token or not secrets.compare_digest(token, DEVICE_TOKEN):
        raise HTTPException(401, "Invalid device token")

@app.get("/health")
def health():
    return {"ok": True, "service": "njabzin-smart-trader-bridge", "version": "2.0"}

@app.post("/api/v1/auth/login")
def login(body: Login):
    if body.username != ADMIN_USERNAME or body.password != ADMIN_PASSWORD:
        raise HTTPException(401, "Invalid username or password")
    return {"access_token": issue_token(body.username), "token_type": "bearer"}

@app.get("/api/v1/status")
def get_status(authorization: Optional[str] = Header(None)):
    require_user(authorization)
    return state

@app.post("/api/v1/settings")
def set_settings(body: Settings, authorization: Optional[str] = Header(None)):
    global pending_command
    require_user(authorization)
    if body.risk is not None and not (0.1 <= body.risk <= 5):
        raise HTTPException(400, "risk must be between 0.1 and 5")
    if body.max_trades is not None and not (1 <= body.max_trades <= 50):
        raise HTTPException(400, "max_trades must be between 1 and 50")
    if body.daily_loss is not None and not (0.5 <= body.daily_loss <= 20):
        raise HTTPException(400, "daily_loss must be between 0.5 and 20")
    if body.running is not None:
        pending_command["running"] = body.running
        state["running"] = body.running
    if body.risk is not None:
        pending_command["risk"] = body.risk
        state["risk"] = body.risk
    if body.max_trades is not None:
        pending_command["max_trades"] = body.max_trades
        state["max_trades"] = body.max_trades
    if body.daily_loss is not None:
        pending_command["daily_loss"] = body.daily_loss
        state["daily_loss"] = body.daily_loss
    pending_command["id"] += 1
    return {"ok": True, "command_id": pending_command["id"], **pending_command}

@app.get("/api/v1/device/poll")
def device_poll(x_device_token: Optional[str] = Header(None)):
    require_device(x_device_token)
    return {
        "command_id": pending_command["id"],
        "running": pending_command["running"],
        "risk": pending_command["risk"],
        "max_trades": pending_command["max_trades"],
        "daily_loss": pending_command["daily_loss"],
    }

@app.post("/api/v1/device/status")
def device_status(body: EAStatus, x_device_token: Optional[str] = Header(None)):
    require_device(x_device_token)
    state.update(body.model_dump())
    state["last_update"] = int(time.time())
    return {"ok": True}

@app.post("/api/v1/device/register")
def device_register(x_device_token: Optional[str] = Header(None)):
    require_device(x_device_token)
    return {"ok": True, "device": "NJABZIN-MT5", "server_time": int(time.time())}
