#!/bin/bash

[ $# == 0 ] && echo "$0 image [args]..." && exit 1

image="$1"; shift

"/home/tw/code/qemu/build/qemu-system-aarch64" \
  "-machine" "virt,virtualization=on,highmem=off,secure=off,gic-version=3" \
  "-cpu" "cortex-a76" \
  "-smp" "2" \
  "-m" "2G" \
  "-serial" "mon:stdio" "-nographic" \
  "-kernel" "${image}" \
  "$@"
