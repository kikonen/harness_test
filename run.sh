#!/bin/env bash
ruby harness.rb \
     --model qwen3.8:27b \
     --base-url https://llm.ikari.fi/v1 \
     --verbose \
     --file test.txt \
     "$@"
