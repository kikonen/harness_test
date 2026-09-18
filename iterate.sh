#!/bin/env bash
. .env
ruby harness_copy.rb \
     --verbose \
     --file \
     "$@"
