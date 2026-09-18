#!/bin/env bash
. .env
ruby harness.rb \
     --verbose \
     --file test.txt \
     "$@"
