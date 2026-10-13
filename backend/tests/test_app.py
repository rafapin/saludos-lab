import unittest
from unittest.mock import patch

from app import app


class AppTests(unittest.TestCase):
    def setUp(self):
        self.client = app.test_client()

    def test_live_does_not_require_database(self):
        response = self.client.get("/live")
        self.assertEqual(response.status_code, 200)
        self.assertEqual(response.get_json()["status"], "ok")

    @patch("app.database_time", return_value="2026-01-01T00:00:00+00:00")
    def test_saludo_returns_database_time(self, _mock_database_time):
        response = self.client.get("/saludo")
        self.assertEqual(response.status_code, 200)
        self.assertEqual(response.get_json()["mensaje"], "Hola desde Azure")
        self.assertEqual(response.get_json()["database_time"], "2026-01-01T00:00:00+00:00")

    @patch("app.database_time", side_effect=RuntimeError("sin conexion"))
    def test_ready_fails_when_database_is_unavailable(self, _mock_database_time):
        with self.assertLogs(level="ERROR"):
            response = self.client.get("/ready")
        self.assertEqual(response.status_code, 503)
        self.assertEqual(response.get_json()["database"], "unavailable")


if __name__ == "__main__":
    unittest.main()
