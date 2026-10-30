import os
import tempfile
from typing import Literal

from fastapi import APIRouter, File, Query, UploadFile
from pydantic import BaseModel, ConfigDict, Field
from starlette.concurrency import run_in_threadpool

from core import config
from services import ai_service, bus_service, location_service

router = APIRouter(prefix="/api")


class Coordinate(BaseModel):
    model_config = ConfigDict(allow_inf_nan=False)
    latitude: float = Field(ge=-90, le=90)
    longitude: float = Field(ge=-180, le=180)


class Place(Coordinate):
    id: str
    name: str


class Stop(Place):
    distance_m: float | None = None


class BusLine(BaseModel):
    id: str
    number: str


class Arrival(BaseModel):
    status: Literal["unavailable", "available"] = "unavailable"
    minutes: int | None = None


class Segment(BaseModel):
    type: Literal["WALK", "BUS"]
    start: Place
    end: Place
    bus: BusLine | None = None
    geometry_status: Literal["available", "unavailable"] = "unavailable"
    coordinates: list[Coordinate] = Field(default_factory=list)
    arrival: Arrival = Field(default_factory=Arrival)


class Route(BaseModel):
    id: str
    segments: list[Segment]
    transfer_count: int


class RouteRequest(BaseModel):
    origin: Coordinate
    destination: Coordinate


class InterpretRequest(BaseModel):
    text: str = Field(min_length=1, max_length=1000, pattern=r"\S")


@router.post("/interpret", response_model=ai_service.Interpretation)
async def interpret(request: InterpretRequest):
    return await ai_service.interpret(request.text)


@router.post("/speech")
async def speech(file: UploadFile = File(...)):
    path = None
    try:
        if not (file.filename or "").lower().endswith(".wav"):
            raise location_service.ServiceError("AUDIO_FORMAT", "WAV 음성 파일만 지원합니다.", 415)
        # 파일 전체를 메모리에 올리지 않고 제한된 크기로 복사한다.
        with tempfile.NamedTemporaryFile(suffix=".wav", delete=False) as output:
            path = output.name
            size = 0
            while chunk := await file.read(65536):
                size += len(chunk)
                if size > config.MAX_AUDIO_BYTES:
                    raise location_service.ServiceError("AUDIO_TOO_LARGE", "음성 파일이 너무 큽니다.", 413)
                output.write(chunk)
        return {"text": await run_in_threadpool(ai_service.transcribe, path)}
    finally:
        await file.close()
        if path and os.path.exists(path):
            os.unlink(path)


@router.get("/locations/search", response_model=list[Place])
def locations(q: str = Query(min_length=1, max_length=200, pattern=r"\S")):
    return location_service.search_locations(q.strip())


@router.get("/bus/stops", response_model=list[Stop])
def stops(latitude: float = Query(ge=-90, le=90), longitude: float = Query(ge=-180, le=180),
          radius_m: float = Query(default=700, gt=0, le=5000)):
    return bus_service.nearby_stops(latitude, longitude, radius_m)


@router.get("/bus/stops/{stop_id}/routes", response_model=list[BusLine])
def stop_routes(stop_id: str):
    return bus_service.stop_routes(stop_id)


@router.post("/bus/routes", response_model=list[Route])
def routes(request: RouteRequest):
    return bus_service.find_routes(request.origin.model_dump(), request.destination.model_dump())
