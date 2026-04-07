from pydantic_settings import BaseSettings


class Settings(BaseSettings):
    database_url: str = "postgresql+asyncpg://nestimer:REDACTED@localhost:5432/nestimer"
    secret_key: str = "change-me-in-production-use-openssl-rand-hex-32"
    algorithm: str = "HS256"
    access_token_expire_minutes: int = 43200  # 30 days
    agent_token_expire_minutes: int = 525600  # 1 year

    class Config:
        env_file = ".env"


settings = Settings()
