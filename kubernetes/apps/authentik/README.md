# Authentik - Identity Provider
# Managed by ArgoCD

This directory contains the ArgoCD Application manifest for Authentik.

## Structure
```
apps/
├── authentik/
│   ├── application.yaml    # ArgoCD Application
│   ├── namespace.yaml      # Namespace
│   ├── values.yaml         # Helm values
│   ├── certificate.yaml    # TLS certificate
│   └── ingress.yaml        # Traefik IngressRoute
```

## Installation
ArgoCD will automatically sync this application when you push to main.
