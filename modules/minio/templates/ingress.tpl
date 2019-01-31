apiVersion: extensions/v1beta1
kind: Ingress
metadata:
  name: minio-ingress
  namespace: ${namespace}
  annotations:
    kubernetes.io/ingress.class: "nginx"
    kubernetes.io/ingress.provider: nginx
    nginx.ingress.kubernetes.io/proxy-body-size: "0"
    nginx.ingress.kubernetes.io/proxy-read-timeout: "900"
    nginx.ingress.kubernetes.io/proxy-request-buffering: "off"
    nginx.ingress.kubernetes.io/proxy-buffering: "off"
  labels:
    app: minio
spec:
  rules:
  - host: ${domain_name}
    http:
      paths:
      - path: /
        backend:
          serviceName: minio
          servicePort: 9000
  tls:
  - hosts:
    - ${domain_name}
