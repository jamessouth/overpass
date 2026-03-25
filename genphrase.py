#!/usr/bin/env python3

# Wordlist: EFF's Large Wordlist (https://www.eff.org/files/2016/07/18/eff_large_wordlist.txt)
# Wordlist License: CC-BY 4.0 (https://creativecommons.org)
# Attribution: Electronic Frontier Foundation

import secrets
import sys

def genpp(numWords):
	with open('./eff_large_wordlist.txt', 'r') as f:
		words=[line.split()[1] for line in f]
	prelim=[secrets.choice(words) for _ in range(numWords)]
	return "-".join(prelim)

if __name__ == "__main__":
	sys.stdout.write(genpp(int(sys.argv[1])))


#log_2_7776=12.9248125036
#ent=round((int(sys.argv[1])*log_2_7776)*10)/10
#print()
#print("Entropy: ", ent)



