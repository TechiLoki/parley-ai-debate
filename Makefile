.PHONY: up down check smoke logs
up:
	docker compose up --build -d
down:
	docker compose down
check:
	sh scripts/check.sh
smoke:
	python3 scripts/smoke.py
logs:
	docker compose logs -f --tail=100 backend ollama model-init
