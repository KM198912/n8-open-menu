#!/bin/sh
# n8-open: run the core testbenches with Icarus Verilog (from WSL)
set -e
cd "$(dirname "$0")"
SRC="../nrom/top.v ../nrom/osmap.v ../nrom/map_nrom.v ../nrom/map_mmc1.v ../nrom/map_mmc3.v ../nrom/map_mmc5.v ../nrom/map_simple.v ../nrom/map_vrc6.v ../nrom/map_fds.v ../nrom/aud_dac.v ../nrom/fds_snd.v ../nrom/mmc5_snd.v"
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
for m in 24 26; do
    echo "== tb_vrc6 (mapper $m)"
    iverilog -g2005 -Ptb_vrc6.M=$m -o tb_vrc6 tb_vrc6.v $SRC
    vvp -n tb_vrc6 | grep -v finish
done
echo "== tb_fds"
iverilog -g2005 -o tb_fds tb_fds.v $SRC
vvp -n tb_fds | grep -v finish
echo "== tb_fds_snd (FDS sound vs tools/n8sim/fds_audio.py, cycle for cycle)"
python3 ../../tools/n8sim/fds_audio.py gen fds_snd_stim.hex
iverilog -g2005 -o tb_fds_snd tb_fds_snd.v ../nrom/fds_snd.v
vvp -n tb_fds_snd | grep -v -e finish -e WARNING
python3 ../../tools/n8sim/fds_audio.py check fds_snd_stim.hex fds_snd_out.txt
echo "== tb_mmc5_snd (MMC5 sound vs tools/n8sim/mmc5_audio.py, cycle for cycle)"
python3 ../../tools/n8sim/mmc5_audio.py gen mmc5_snd_stim.hex
iverilog -g2005 -o tb_mmc5_snd tb_mmc5_snd.v ../nrom/mmc5_snd.v
vvp -n tb_mmc5_snd | grep -v -e finish -e WARNING
python3 ../../tools/n8sim/mmc5_audio.py check mmc5_snd_stim.hex mmc5_snd_out.txt
