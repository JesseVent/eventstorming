#!/usr/bin/env python3
"""Smoke test for code_analyzer.sh: builds a tiny FastAPI + Celery + Express fixture in a
temp dir, runs the analyzer, and asserts the EventStorming signals come out.

    python3 test_code_analyzer.py
"""
import json
import subprocess
import sys
import tempfile
from pathlib import Path

HERE = Path(__file__).resolve().parent
ANALYZER = HERE / "code_analyzer.sh"

FIXTURE = {
    "app/main.py": """
from fastapi import FastAPI
from core.urls import router as api_router

app = FastAPI()
app.include_router(api_router, prefix="/api")
""",
    "app/core/urls.py": """
from fastapi import APIRouter
from modules.orders.router import router as orders_router

router = APIRouter()
router.include_router(orders_router)
""",
    "app/core/celery.py": """
from celery import Celery
from celery.schedules import crontab

celery_app = Celery("fx")
celery_app.conf.beat_schedule = {
    "expire-orders": {"task": "tasks.expire_orders", "schedule": crontab(minute="*/5")},
    "purge": {"task": "tasks.purge_old", "schedule": crontab(hour="3")},
}
""",
    "app/modules/orders/router.py": """
from fastapi import APIRouter, BackgroundTasks, Depends, HTTPException
from common.permissions import has_permission
from modules.orders.service import OrderService
from modules.users.models import Users, UserRoleType
from tasks import send_receipt

router = APIRouter(
    prefix="/orders",
    tags=["orders"],
    dependencies=[Depends(has_permission([UserRoleType.CLINICIAN]))],
)


@router.post("")
async def create_order(
    payload: dict,
    background_tasks: BackgroundTasks,
    _: Users = Depends(has_permission(["ADMIN"])),
):
    service = OrderService()
    order = await service.create(payload)
    if order is None:
        raise HTTPException(status_code=409, detail="duplicate")
    background_tasks.add_task(service.notify_admin, order.id)
    send_receipt.delay(order.id)
    return {"id": order.id}


@router.get("/{order_id}")
async def get_order(order_id: int):
    return await OrderService().find(order_id)
""",
    "app/modules/orders/service.py": """
import asyncio
from modules.orders.repository import OrderRepository


class OrderService:
    def __init__(self):
        self.repo = OrderRepository()

    async def create(self, payload):
        if payload.get("amount", 0) <= 0:
            raise ValueError("amount must be positive")
        if await self.repo.find_one(payload["ref"]):
            return None
        order = await self.repo.create(payload)
        asyncio.create_task(self.warm_cache(order.id))
        return order

    async def find(self, order_id):
        return await self.repo.find_one(order_id)

    async def notify_admin(self, order_id):
        return order_id

    async def warm_cache(self, order_id):
        return order_id
""",
    "app/modules/orders/repository.py": """
from sqlalchemy import select
from modules.orders.models import Order


class OrderRepository:
    def __init__(self, session=None):
        self.session = session
        self.model = Order

    async def find_one(self, key):
        result = await self.session.execute(select(self.model).where(self.model.ref == key))
        return result.scalars().first()

    async def create(self, payload):
        obj = self.model(**payload)
        self.session.add(obj)
        await self.session.commit()
        return obj
""",
    "app/modules/orders/models.py": """
from sqlalchemy.orm import declarative_base

Base = declarative_base()


class Order(Base):
    __tablename__ = "orders"


class AuditLog(Base):
    __tablename__ = "audit_logs"
""",
    "app/tasks.py": """
from celery import shared_task
from core.celery import celery_app


@celery_app.task
def send_receipt(order_id):
    return order_id


@shared_task
def expire_orders():
    return True
""",
    "web/api.ts": """
import express from "express";
import cron from "node-cron";
import { Queue } from "bullmq";

const router = express.Router();
const emailQueue = new Queue("email");

router.post("/orders", requireRole("admin"), async (req, res) => {
  const order = await prisma.order.create({ data: req.body });
  await emailQueue.add("receipt", { id: order.id });
  res.json(order);
});

cron.schedule("*/5 * * * *", async () => {
  await prisma.order.updateMany({ where: { stale: true }, data: { status: "expired" } });
});

setInterval(() => console.log("tick"), 60000);

export async function cancelOrder(req, res) {
  if (!req.user) return res.status(401).json({ error: "sign in" });
  throw new ConflictError("already shipped");
}
""",
}


def run(schema, root, out):
    subprocess.run(["bash", str(ANALYZER), "-s", schema, "-o", str(out), str(root)],
                   check=True, capture_output=True, text=True)
    return json.load(open(out))


def main():
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp)
        for rel, body in FIXTURE.items():
            (root / rel).parent.mkdir(parents=True, exist_ok=True)
            (root / rel).write_text(body.lstrip())

        d = run("full", root, root / "full.json")
        run("tool", root, root / "tool.json")    # used to crash on a missing field_guide
        run("model", root, root / "model.json")

        fns = [fn for f in d["files"] for fn in f.get("fns", [])]
        routes = {(r["method"], r.get("full_path") or r.get("path")) for r in d["routes"]}
        db_writers = {fn["n"] for fn in fns if "database" in (fn.get("io_out") or [])}
        reactions = d["reactions"]
        kinds = {r["kind"] for r in reactions}
        tkinds = {t["kind"] for t in d["time_triggers"]}
        tasks = {fn["n"] for fn in fns if fn.get("task")}
        leaks = [c for fn in fns for c in fn.get("→", []) if "Call(" in c or "ctx=" in c]

        assert ("POST", "/api/orders") in routes, routes                      # include_router prefixes joined
        assert ("GET", "/api/orders/{order_id}") in routes, routes
        assert "create" in db_writers, db_writers                              # self.session.add seen as a write
        assert {"background", "queue", "async"} <= kinds, kinds                # add_task, .delay, create_task
        assert any(r["how"] == "emailQueue.add" for r in reactions), reactions # bullmq
        assert {"beat", "cron", "interval"} <= tkinds, tkinds                  # beat_schedule, node-cron, setInterval
        assert tasks == {"send_receipt", "expire_orders"}, tasks               # @celery_app.task, @shared_task
        assert not leaks, leaks[:3]                                            # no ast.dump text in call hints

        # Roles from permission guards: router-level dependencies plus handler-level Depends
        post = next(r for r in d["routes"] if r["method"] == "POST" and r.get("full_path") == "/api/orders")
        assert post.get("roles") == ["ADMIN", "CLINICIAN"], post
        # Express: an inline arrow handler is still a route, and its middleware names the guard and role
        js = [r for r in d["routes"] if r.get("framework") == "express" and r.get("path") == "/orders"]
        assert len(js) == 1 and js[0]["guards"] == ["requireRole"] and js[0]["roles"] == ["admin"], js

        # Refusals: the handler's own raise with its guard, plus a ValueError one hop down the call graph
        refs = post.get("refusals") or []
        own = next((r for r in refs if r["fn"] == "create_order"), None)
        assert own and own["status"] == 409 and own["msg"] == "duplicate" and own["when"] == "order is None", refs
        assert any(r["exc"] == "ValueError" and r["fn"] == "create" and "amount" in r["when"] for r in refs), refs
        cancel = next(fn for fn in fns if fn["n"] == "cancelOrder")
        assert {(r["exc"], r.get("status")) for r in cancel["refusals"]} == {("response", 401), ("ConflictError", None)}, cancel
        # Absences: a beat task nothing defines, a model nothing references
        ab = d["absences"]
        assert [t["task"] for t in ab["scheduled_tasks_undefined"]] == ["tasks.purge_old"], ab
        assert [m["model"] for m in ab["models_unreferenced"]] == ["AuditLog"], ab
        assert "AuditLog" in {m["model"] for m in ab["models_never_constructed"]}, ab
    print("ok: routes, db writers, reactions, time triggers, tasks, refusals, absences, no leaks")


if __name__ == "__main__":
    sys.exit(main())
