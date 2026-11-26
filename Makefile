.PHONY: help lint test coverage up down monitoring monitoring-down health dashboards kind-up kind-deploy kind-down tf-fmt

help:            ## list targets
	@grep -E '^[a-zA-Z_-]+:.*##' $(MAKEFILE_LIST) | awk -F':.*## ' '{printf "  %-16s %s\n", $$1, $$2}'

lint:            ## eslint + shellcheck
	cd app && npm run lint
	shellcheck scripts/*.sh

test:            ## unit tests
	cd app && npm test

coverage:        ## unit tests with coverage gate (80% lines)
	cd app && npm run test:coverage

up:              ## run the app on :8080
	docker compose up -d --build

down:            ## stop the app
	docker compose down

monitoring:      ## app + full observability stack (Grafana on :3000)
	@test -f .env || (echo "Create .env first: cp .env.example .env" && exit 1)
	docker compose -f docker-compose.yml -f docker-compose.monitoring.yml up -d --build

monitoring-down: ## stop everything (add -v manually to delete data volumes)
	docker compose -f docker-compose.yml -f docker-compose.monitoring.yml down

health:          ## run the health script once
	./scripts/system_health.sh

dashboards:      ## regenerate Grafana dashboard JSON
	python3 tools/generate_dashboards.py

kind-up:         ## create kind cluster + ingress-nginx + metrics-server
	kind create cluster --config k8s/kind-config.yaml
	kubectl apply -f https://kind.sigs.k8s.io/examples/ingress/deploy-ingress-nginx.yaml
	kubectl apply -f https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml
	kubectl -n kube-system patch deployment metrics-server --type=json \
	  -p '[{"op":"add","path":"/spec/template/spec/containers/0/args/-","value":"--kubelet-insecure-tls"}]'
	kubectl -n ingress-nginx wait --for=condition=ready pod -l app.kubernetes.io/component=controller --timeout=180s

kind-deploy:     ## build, load and deploy v1.0.0 to kind
	docker build -t devops-task-app:1.0.0 --build-arg VERSION=1.0.0 app
	kind load docker-image devops-task-app:1.0.0 --name devops-task
	@test -f k8s/secret.env || cp k8s/secret.env.example k8s/secret.env
	kubectl apply -k k8s
	kubectl -n devops-task rollout status deployment/app

kind-down:       ## delete the kind cluster
	kind delete cluster --name devops-task

tf-fmt:          ## format terraform
	terraform fmt -recursive terraform
