if [ -z "$HOME" ]
then
  echo HOME not in environment, guessing...
  export HOME=$(awk -F: -v v="$USER" '{if ($1==v) print $6}' /etc/passwd)
fi

if [ ! -d hudson ]
then
  git clone https://github.com/ItachiSan/hudson.git -b cm
fi

cd hudson
## Get rid of possible local changes
git reset --hard
git pull -s resolve

exec ./build.sh
