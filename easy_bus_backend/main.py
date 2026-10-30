
from fastapi import FastAPI

# AI 쉬운 버스 백엔드 서버
app = FastAPI(
    title="Easy AI Bus API",
    description="강릉시 AI 음성 버스 안내 서비스",
    version="0.1.0"
)

# 서버 정상 실행 여부 확인
@app.get("/api/health")
def health_check():
    return {
        "status": "ok",
        "message": "Easy AI Bus 서버 정상 실행"
    }
