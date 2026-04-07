from contextlib import asynccontextmanager

from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware

import os

from .config import settings
from .database import init_db
from .routers import auth, devices, agent


@asynccontextmanager
async def lifespan(app: FastAPI):
    if settings.secret_key.startswith("change-me"):
        raise RuntimeError(
            "FATAL: Set SECRET_KEY environment variable. "
            "Generate one with: openssl rand -hex 32"
        )
    await init_db()
    yield


ALLOWED_ORIGINS = os.getenv("CORS_ORIGINS", "https://my.nestimer.com,http://localhost:3080,http://localhost:5173").split(",")

app = FastAPI(
    title="NesTimer API",
    description="NesTimer parental controls API",
    version="2.0.0",
    lifespan=lifespan,
)

app.add_middleware(
    CORSMiddleware,
    allow_origins=ALLOWED_ORIGINS,
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

app.include_router(auth.router, prefix="/api/v1")
app.include_router(devices.router, prefix="/api/v1")
app.include_router(agent.router, prefix="/api/v1")


@app.get("/health")
async def health():
    return {"status": "ok"}
