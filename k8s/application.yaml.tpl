apiVersion: v1
kind: Namespace
metadata:
  name: ${NAMESPACE}
  labels:
    app.kubernetes.io/part-of: ${EXPERIMENT_TAG}
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: ${APP_NAME}-code
  namespace: ${NAMESPACE}
data:
  app.py: |
    import json
    import os
    import random
    import socket
    import time
    from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

    import boto3

    REGION = os.environ["AWS_REGION"]
    TABLE_NAME = os.environ["TABLE_NAME"]
    POD_NAME = os.environ.get("POD_NAME", socket.gethostname())
    table = boto3.resource("dynamodb", region_name=REGION).Table(TABLE_NAME)

    class Handler(BaseHTTPRequestHandler):
        def log_message(self, *_):
            return

        def send_json(self, code, payload):
            body = json.dumps(payload).encode()
            self.send_response(code)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def do_GET(self):
            if self.path == "/healthz":
                self.send_json(200, {"ok": True, "region": REGION, "pod": POD_NAME})
                return

            started = time.perf_counter()
            key = f"item-{random.randrange(100)}"
            try:
                table.get_item(Key={"pk": key}, ConsistentRead=False)
                if random.random() < 0.01:
                    table.update_item(
                        Key={"pk": f"counter-{REGION}"},
                        UpdateExpression="ADD request_count :one SET last_writer = :region",
                        ExpressionAttributeValues={":one": 1, ":region": REGION},
                    )
                self.send_json(
                    200,
                    {
                        "ok": True,
                        "region": REGION,
                        "pod": POD_NAME,
                        "ddb_key": key,
                        "latency_ms": round((time.perf_counter() - started) * 1000, 2),
                    },
                )
            except Exception as exc:
                self.send_json(
                    503,
                    {
                        "ok": False,
                        "region": REGION,
                        "pod": POD_NAME,
                        "error": type(exc).__name__,
                    },
                )

    ThreadingHTTPServer(("0.0.0.0", 8080), Handler).serve_forever()
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: ${APP_NAME}
  namespace: ${NAMESPACE}
  labels:
    app: ${APP_NAME}
spec:
  replicas: 1
  strategy:
    rollingUpdate:
      maxUnavailable: 0
      maxSurge: 25%
  selector:
    matchLabels:
      app: ${APP_NAME}
  template:
    metadata:
      labels:
        app: ${APP_NAME}
    spec:
      nodeSelector:
        node.kubernetes.io/instance-type: m7i.xlarge
      terminationGracePeriodSeconds: 10
      containers:
        - name: api
          image: public.ecr.aws/lambda/python:3.13
          command:
            - python3
          args:
            - /opt/app/app.py
          ports:
            - name: http
              containerPort: 8080
          env:
            - name: AWS_REGION
              value: ${DEPLOY_REGION}
            - name: TABLE_NAME
              value: ${TABLE_NAME}
            - name: POD_NAME
              valueFrom:
                fieldRef:
                  fieldPath: metadata.name
          resources:
            requests:
              cpu: 300m
              memory: 192Mi
            limits:
              cpu: "1"
              memory: 512Mi
          readinessProbe:
            httpGet:
              path: /healthz
              port: http
            periodSeconds: 5
            failureThreshold: 12
          livenessProbe:
            httpGet:
              path: /healthz
              port: http
            periodSeconds: 15
            failureThreshold: 4
          volumeMounts:
            - name: code
              mountPath: /opt/app
              readOnly: true
      volumes:
        - name: code
          configMap:
            name: ${APP_NAME}-code
---
apiVersion: v1
kind: Service
metadata:
  name: ${APP_NAME}
  namespace: ${NAMESPACE}
  annotations:
    service.beta.kubernetes.io/aws-load-balancer-scheme: internet-facing
    service.beta.kubernetes.io/aws-load-balancer-nlb-target-type: ip
spec:
  type: LoadBalancer
  loadBalancerClass: eks.amazonaws.com/nlb
  selector:
    app: ${APP_NAME}
  ports:
    - name: http
      port: 80
      targetPort: http
---
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: ${APP_NAME}
  namespace: ${NAMESPACE}
spec:
  minReplicas: 1
  maxReplicas: ${HPA_MAX_REPLICAS}
  scaleTargetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: ${APP_NAME}
  behavior:
    scaleDown:
      stabilizationWindowSeconds: 300
    scaleUp:
      stabilizationWindowSeconds: 0
  metrics:
    - type: Resource
      resource:
        name: cpu
        target:
          type: Utilization
          averageUtilization: 60
