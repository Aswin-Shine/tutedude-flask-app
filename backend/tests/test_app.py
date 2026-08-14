"""
Tests for the /api/submit endpoint.

MONGO_URI has to be set before `app` is imported, since app.py raises
RuntimeError at import time if it's missing (that's intentional, see the
comment in app.py). The value here is never a real connection, pymongo's
MongoClient doesn't actually connect until you use it, and every test
that touches the database mocks `collection.insert_one` instead of
hitting a real Mongo cluster, so a bogus URI is fine.
"""
import os

os.environ.setdefault("MONGO_URI", "mongodb://localhost:27017/test_db_never_used")

import pytest
from unittest.mock import patch

import app as app_module


@pytest.fixture
def client():
    app_module.app.config["TESTING"] = True
    with app_module.app.test_client() as client:
        yield client


def test_missing_json_body_returns_400(client):
    response = client.post("/api/submit", data="not json", content_type="text/plain")
    assert response.status_code == 400


def test_missing_username_returns_400(client):
    response = client.post("/api/submit", json={"email": "test@example.com"})
    assert response.status_code == 400
    body = response.get_json()
    assert body["success"] is False
    assert "Missing required data fields" in body["error"]


def test_missing_email_returns_400(client):
    response = client.post("/api/submit", json={"username": "test_user"})
    assert response.status_code == 400


def test_valid_submission_returns_200(client):
    # Mocks the actual database write. This test is checking the route's
    # request-handling logic (validation, response shape), not whether
    # MongoDB itself works, that's not something a unit test should be
    # asserting against a real cluster.
    with patch.object(app_module.collection, "insert_one") as mock_insert:
        response = client.post(
            "/api/submit", json={"username": "test_user", "email": "test@example.com"}
        )
        assert response.status_code == 200
        body = response.get_json()
        assert body["success"] is True
        mock_insert.assert_called_once_with(
            {"username": "test_user", "email": "test@example.com"}
        )


def test_database_error_returns_500(client):
    # If the insert itself throws (real Mongo down, bad connection, etc),
    # the route should surface a 500 with the error message, not crash
    # the whole process or return a misleading 200.
    with patch.object(app_module.collection, "insert_one", side_effect=Exception("connection refused")):
        response = client.post(
            "/api/submit", json={"username": "test_user", "email": "test@example.com"}
        )
        assert response.status_code == 500
        body = response.get_json()
        assert body["success"] is False
