from pydantic_settings import BaseSettings


class Settings(BaseSettings):
    # Local-dev fallback only. Real credentials come from .env / environment.
    # Never commit a working password here — see DB_PASSWORD / SECRET_KEY in .env.
    database_url: str = "postgresql+asyncpg://nestimer:CHANGE_ME@localhost:5432/nestimer"
    secret_key: str = "change-me-in-production-use-openssl-rand-hex-32"
    algorithm: str = "HS256"
    access_token_expire_minutes: int = 43200  # 30 days
    agent_token_expire_minutes: int = 525600  # 1 year

    class Config:
        env_file = ".env"


settings = Settings()
