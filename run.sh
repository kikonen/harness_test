#!/bin/env bash
. .env
bundle exec ruby harness.rb \
     --verbose \
     "$@"
