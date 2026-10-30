
from fastapi import FastAPI
from fastapi.responses import JSONResponse
from api.routes import router
from services.location_service import ServiceError

# AI 쉬운 버스 백엔드 서버
app = FastAPI(
    title="Easy AI Bus API",
    description="강릉시 AI 음성 버스 안내 서비스",
    version="0.1.0"
)

app.include_router(router)


# 서비스 오류는 앱에서 이해할 수 있는 한국어 안내와 오류 코드로 전달한다.
@app.exception_handler(ServiceError)
async def service_error_handler(request, exc: ServiceError):
    return JSONResponse(status_code=exc.status, content={
        "detail": {"code": exc.code, "message": exc.message}
    })

# 서버 정상 실행 여부 확인
@app.get("/api/health")
def health_check():
    return {
        "status": "ok",
        "message": "Easy AI Bus 서버 정상 실행"
    }
