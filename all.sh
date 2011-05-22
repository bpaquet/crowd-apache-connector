cd Atlassian-Crowd-1.2.3
debuild -us -uc -sa
cd ..
cd Apache-CrowdAuth-1.2.3
debuild -us -uc -sa
cd ..
./purge.sh
