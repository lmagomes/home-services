#!/bin/bash
sops decrypt .secrets/secrets.yaml | yq .secrets | while read -r secret; do
  IFS=": " read -r name value <<< "$secret"

  if podman secret exists "$name"; then
    echo "Secret $name already exists, skipping..."
    continue
  else
    echo "Creating secret $name..."
  fi

  echo -n $value | podman secret create $name -
done