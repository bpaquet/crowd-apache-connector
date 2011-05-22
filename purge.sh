rm -f *.build *.dsc *.changes *.tar.gz
cd Atlassian-Crowd-1.2.3
debuild clean
cd ..
cd Apache-CrowdAuth-1.2.3
debuild clean
