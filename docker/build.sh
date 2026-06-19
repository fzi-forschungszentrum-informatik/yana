#!/bin/env bash
docker build -t ghcr.io/neher-fzi/yana:latest -f "$(dirname "$0")/Dockerfile" "$(dirname "$0")/.."
