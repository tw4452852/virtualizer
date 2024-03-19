# virtualizer
A POC to implement a hypervisor on bare metal to run linux kernel in a virtualized environment.

## How to run in native environment

Suppose you've already had a built linux kernel.

```
# aarch64
> ./src/arch/aarch64/run.sh /path/to/your/linux_kernel

```

## How to run in virtualized environment

```
# aarch64
> zig build -Dkernel=/path/to/your/linux_kernel run
```

Have fun!