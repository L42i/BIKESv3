
please make SURE that you have the proper media files installed BEFORE you run anything and BEFORE you sync. 

If you run sync folder and you don't have the files it WILL delete them from the PI. 

CRUCIAL COMMANDS: 
ansible-playbook -i ./utility/config/bikes.ini utility/ping.yml
ansible-playbook -k -i ./utility/config/bikes.ini sync_folder.yml 
ansible-playbook -k -i ./utility/config/bikes.ini concepts/soundscapes/soundscapes.yml -e soundscape="marine"
ansible-playbook -i ./utility/config/bikes.ini utility/kill_everything.yml
