#!/bin/bash

winners_recent_full_file="$1"
blk_diff="$2"
blk_reward="$3"
seconds_year="31536000"

#get avg bouns hr
rounds_count="168"
bonus_hr=$(head -$rounds_count $winners_recent_full_file |awk '{print $4}' |sed 's/kH\/s//g' |echo "$(paste -sd+ |bc)/$rounds_count" |bc -l |awk '{printf "%.2f\n", $1}')
bonus_hash_year=$(head -$rounds_count $winners_recent_full_file |awk '{print $4}' |sed 's/kH\/s//g' |echo "$(paste -sd+ |bc)/$rounds_count * (1000) * ($seconds_year)" |bc -l)

#calc yearly raffle reward: (hashes / diff) * (reward_per_block)
reward=$(echo "($bonus_hash_year / $blk_diff) * ($blk_reward)" |bc -l |awk '{printf "%.2f\n", $1}')
echo "Raffle HR: $bonus_hr kH/s"
echo "Raffle Reward: $reward XMR/year" && echo

#vip yearly reward
count=$(head -$rounds_count $winners_recent_full_file |grep -w "vip" |wc -l)
while [ "$count" -eq "0" ]
do
	rounds_count=$(echo "$rounds_count + 24" |bc)
	count=$(head -$rounds_count $winners_recent_full_file |grep -w "vip" |wc -l)
done
if [ "$count" -ne "0" ];then
players_avg=$(head -$rounds_count $winners_recent_full_file |grep -w "vip" |awk '{print $8}' |echo "$(paste -sd+ |bc)/$count" |bc -l)
reward_vip=$(echo "($reward * ($count / $rounds_count))" |bc -l |awk '{printf "%.2f\n", $1}')
reward_vip_player=$(echo "$reward_vip / $players_avg" |bc -l |awk '{printf "%.4f\n", $1}')
echo "Round vip: $reward_vip XMR/year"
echo "Round: vip Player: $reward_vip_player XMR/year" && echo
fi

#mvp yearly reward
count=$(head -$rounds_count $winners_recent_full_file |grep -w "mvp" |wc -l)
while [ "$count" -eq "0" ]
do
	rounds_count=$(echo "$rounds_count + 24" |bc)
	count=$(head -$rounds_count $winners_recent_full_file |grep -w "mvp" |wc -l)
done
if [ "$count" -ne "0" ];then
players_avg=$(head -$rounds_count $winners_recent_full_file |grep -w "mvp" |awk '{print $8}' |echo "$(paste -sd+ |bc)/$count" |bc -l)
reward_mvp=$(echo "($reward * ($count / $rounds_count))" |bc -l |awk '{printf "%.2f\n", $1}')
reward_mvp_player=$(echo "$reward_mvp / $players_avg" |bc -l |awk '{printf "%.3f\n", $1}')
echo "Round mvp: $reward_mvp XMR/year"
echo "Round: mvp Player: $reward_mvp_player XMR/year" && echo
fi

#donor yearly reward
count=$(head -$rounds_count $winners_recent_full_file |grep -w "donor" |wc -l)
while [ "$count" -eq "0" ]
do
	rounds_count=$(echo "$rounds_count + 24" |bc)
	count=$(head -$rounds_count $winners_recent_full_file |grep -w "donor" |wc -l)
done
if [ "$count" -ne "0" ];then
players_avg=$(head -$rounds_count $winners_recent_full_file |grep -w "donor" |awk '{print $8}' |echo "$(paste -sd+ |bc)/$count" |bc -l)
reward_donor=$(echo "($reward * ($count / $rounds_count))" |bc -l |awk '{printf "%.2f\n", $1}')
reward_donor_player=$(echo "$reward_donor / $players_avg + $reward_vip_player" |bc -l |awk '{printf "%.3f\n", $1}')
echo "Round: donor: $reward_donor XMR/year"
echo "Round: donor Player: $reward_donor_player XMR/year" && echo
fi

#donor_vip yearly reward
count=$(head -$rounds_count $winners_recent_full_file |grep -w "donor_vip" |wc -l)
players_avg=$(head -$rounds_count $winners_recent_full_file |grep -w "donor_vip" |awk '{print $8}' |echo "$(paste -sd+ |bc)/$count" |bc -l)
reward_donor_vip=$(echo "($reward * ($count / $rounds_count))" |bc -l |awk '{printf "%.2f\n", $1}')
reward_donor_vip_player=$(echo "$reward_donor_vip / $players_avg + $reward_donor_player" |bc -l |awk '{printf "%.2f\n", $1}')
echo "Round: donor_vip: $reward_donor_vip XMR/year"
echo "Round: donor_vip Player: $reward_donor_vip_player XMR/year" && echo

#donor_whale yearly reward
count=$(head -$rounds_count $winners_recent_full_file |grep -w "donor_whale" |wc -l)
players_avg=$(head -$rounds_count $winners_recent_full_file |grep -w "donor_whale" |awk '{print $8}' |echo "$(paste -sd+ |bc)/$count" |bc -l)
reward_donor_whale=$(echo "($reward * ($count / $rounds_count))" |bc -l |awk '{printf "%.2f\n", $1}')
reward_donor_whale_player=$(echo "$reward_donor_whale / $players_avg + $reward_donor_vip_player" |bc -l |awk '{printf "%.2f\n", $1}')
echo "Round: donor_whale: $reward_donor_whale XMR/year"
echo "Round: donor_whale Player: $reward_donor_whale_player XMR/year" && echo

#donor_mega yearly reward
count=$(head -$rounds_count $winners_recent_full_file |grep -w "donor_mega" |wc -l)
if [ "$count" -ne "0" ];then
	players_avg=$(head -$rounds_count $winners_recent_full_file |grep -w "donor_mega" |awk '{print $8}' |echo "$(paste -sd+ |bc)/$count" |bc -l)
	reward_donor_mega=$(echo "($reward * ($count / $rounds_count))" |bc -l |awk '{printf "%.2f\n", $1}')
	reward_donor_mega_player=$(echo "$reward_donor_mega / $players_avg + $reward_donor_whale_player" |bc -l |awk '{printf "%.2f\n", $1}')
else
	reward_donor_mega="0"
	reward_donor_mega_player="0"
fi
echo "Round: donor_mega: $reward_donor_mega XMR/year"
echo "Round: donor_mega Player: $reward_donor_mega_player XMR/year" && echo
