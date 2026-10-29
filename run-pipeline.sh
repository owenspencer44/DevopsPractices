#!/usr/bin/env bash

container=""
step_name=""

# Read pipeline.yml one line at a time
while IFS= read -r line || [[ -n "$line" ]]; do

  # "container: mylinux" → remember the container name
  if [[ "$line" =~ ^container:[[:space:]]*(.*)$ ]]; then
    container="${BASH_REMATCH[1]}"

  # "  - name: Say hello" → remember the step name
  elif [[ "$line" =~ ^[[:space:]]*-[[:space:]]+name:[[:space:]]*(.*)$ ]]; then
    step_name="${BASH_REMATCH[1]}"

  # "    run: echo hi" → run that command inside the container
  elif [[ "$line" =~ ^[[:space:]]+run:[[:space:]]*(.*)$ ]]; then
    echo "▶ $step_name"
    if ! docker exec "$container" bash -c "${BASH_REMATCH[1]}" < /dev/null; then
      echo "✘ Step failed: $step_name"
      exit 1
    fi
  fi

done < pipeline.yml

echo "✔ Pipeline passed"
