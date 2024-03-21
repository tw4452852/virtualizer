#!/bin/bash

[ $# == 0 ] && echo "$0 image [args]..." && exit 1

image="$1"; shift

"/home/tw/code/qemu/build/qemu-system-aarch64" \
  "-machine" "virt,virtualization=on,highmem=off,secure=off" \
  "-cpu" "cortex-a76" \
  "-smp" "4" \
  "-m" "2G" \
  "-serial" "mon:stdio" "-nographic" \
  "-kernel" "${image}" \
  "$@"
