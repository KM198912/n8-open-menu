#!/bin/sh
# n8-open: run the core testbenches with Icarus Verilog (from WSL)
set -e
cd "$(dirname "$0")"
SRC="../nrom/top.v ../nrom/osmap.v ../nrom/map_nrom.v ../nrom/map_mmc1.v ../nrom/map_mmc3.v ../nrom/map_mmc5.v ../nrom/map_simple.v"
for tb in tb_mmc1 tb_mmc3 tb_mmc5; do
    echo "== $tb"
    iverilog -g2005 -o $tb $tb.v $SRC
    vvp -n $tb | grep -v '\$finish'
done
for m in 2 3 7 66; do
    echo "== tb_simple (mapper $m)"
    iverilog -g2005 -Ptb_simple.M=$m -o tb_simple tb_simple.v $SRC
    vvp -n tb_simple | grep -v '\$finish'
done
