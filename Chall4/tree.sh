#!/bin/bash

PROJECT_DIR="Hacktify"

mkdir -p "$PROJECT_DIR"

cd "$PROJECT_DIR" || exit 1

touch Assessment.xlsx
touch Description.md
touch Red-Writeup.md
touch service_availability_ttp.yaml
touch setup_ttp.yaml
touch red_attack_script.sh
touch setup.sh

chmod +x red_attack_script.sh
chmod +x setup.sh

echo "Directory structure created successfully!"

tree .
