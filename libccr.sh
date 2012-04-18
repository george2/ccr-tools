#!/bin/bash
# libccr.sh
# A bunch of bash functions for using the CCR
# Some pieces are taken from packer and aurvote, so consider this as GPL3


# Called whenever anything needs to be run as root ($@ is the command)
runasroot() {
  if [[ $UID -eq 0 ]]; then
    "$@"
  elif sudo -v &>/dev/null && sudo -l "$@" &>/dev/null; then
    sudo "$@"
  else
    echo -n "root "
    # Hack: need to echo to make sure all of the args get in the single set of quotes
    su root -c "$(echo $@)"
  fi
}

# Source makepkg.conf file
sourcemakepkgconf() {
  . "$makepkgconf"
  [[ -r "$usermakepkgconf" ]] && . "$usermakepkgconf"
}

# Parse IgnorePkg and --ignore, put in globally accessible ignoredpackages array
getignoredpackages() {
  IFS=','
  ignoredpackages=($ignorearg)
  IFS=$'\n'" "
  ignoredpackages+=( $(grep '^ *IgnorePkg' "$pacmanconf" | cut -d '=' -f 2-) )
}

# Checks to see if $1 is an ignored package
isignored() {
  [[ " ${ignoredpackages[@]} " =~ " $1 " ]]
}

# Tests whether $1 exists on the ccr
existsinccr() {
  rpcinfo "$1"
  [[ "$(jshon -Qe type -u < "$tmpdir/$1.info")" = "info" ]]
}

# Tests whether $1 exists in pacman
existsinpacman() {
  pacman -Si -- "$1" &>/dev/null
}

# Tests whether $1 is provided in pacman, sets globally accessibly providepkg var
providedinpacman() {
  IFS=$'\n'
  providepkg=( $(pacman -Ssq -- "^$1$") )
}

# Tests whether $1 exists in a pacman group
existsinpacmangroup() {
  [[ $(pacman -Sgq "$1") ]]
}

# Tests whether $1 exists locally
existsinlocal() {
  pacman -Qq -- "$1" &>/dev/null
}

# Scrapes the ccr deps from PKGBUILDS and puts in globally available dependencies array
scrapeccrdeps() {
  pkginfo "$1"
  . "$tmpdir/$1.PKGBUILD"
  IFS=$'\n'
  dependencies=( $(echo -e "${depends[*]}\n${makedepends[*]}" | sed -e 's/=.*//' -e 's/>.*//' -e 's/<.*//'| sort -u) )
}

# Finds dependencies of package $1
# Sets pacmandeps and ccrdeps array, which can be accessed globally after function runs
finddeps() {
  # loop through dependencies, if not installed, determine if pacman or ccr deps
  pacmandeps=()
  ccrdeps=()
  scrapeccrdeps "$1"
  missingdeps=( $(pacman -T "${dependencies[@]}") )
  while [[ $missingdeps ]]; do
    checkdeps=()
    for dep in "${missingdeps[@]}"; do
      if [[ " $1 ${ccrdeps[@]} ${pacmandeps[@]} " =~ " $dep " ]];  then
        continue
      fi
      if existsinpacman "$dep"; then
        pacmandeps+=("$dep")
      elif existsinccr "$dep"; then
        if [[ $ccrdeps ]]; then
          ccrdeps=("$dep" "${ccrdeps[@]}")
        else
          ccrdeps=("$dep")
        fi
        checkdeps+=("$dep")
      elif providedinpacman "$dep"; then
        pacmandeps+=("$providepkg")
      else
        [[ $option = "install" ]] &&  err "Dependency \`$dep' of \`$1' does not exist."
        echo "Dependency \`$dep' of \`$1' does not exist."
        return 1
      fi
    done
    missingdeps=()
    for dep in "${checkdeps[@]}"; do
      scrapeccrdeps "$dep"
      for depdep in "${dependencies[@]}"; do
        [[ $(pacman -T "$depdep") ]] && missingdeps+=("$depdep")
      done
    done
  done
  return 0
}

# Displays a progress bar ($1 is numerator, $2 is denominator, $3 is candy/normal)
ccrbar() {
  # Delete line
  printf "\033[0G"
  
  # Get vars for output
  beginline=" ccr"
  beginbar="["
  endbar="] "
  perc="$(($1*100/$2))"
  width="$(stty size)"
  width="${width##* }"
  charsbefore="$((${#beginline}+${#1}+${#2}+${#beginbar}+3))"
  spaces="$((51-$charsbefore))"
  barchars="$(($width-51-7))"
  hashes="$(($barchars*$perc/100))" 
  dashes="$(($barchars-$hashes))"

  # Print output
  printf "$beginline %${spaces}s$1  $2 ${beginbar}" ""

  # ILoveCandy
  if [[ $3 = candy ]]; then
    for ((n=1; n<$hashes; n++)); do
      if (( (n==($hashes-1)) && ($dashes!=0) )); then
        (($n%2==0)) && printf "\e[1;33mc\e[0m" || printf "\e[1;33mC\e[0m"
      else
        printf "-"
      fi
    done
    for ((n=1; n<$dashes; n++)); do
      N=$(( $n+$hashes ))
      (($hashes>0)) && N=$(($N-1))
      (($N%3==0)) && printf "o" || printf " "
    done
  else
    for ((n=0; n<$hashes; n++)); do
      printf "#"
    done
    for ((n=0; n<$dashes; n++)); do
      printf "-"
    done
  fi
  printf "%s%3s%%\r" ${endbar} ${perc}
}

rpcinfo() {
  if ! [[ -f "$tmpdir/$1.info" ]]; then
    curl -LfGs --data-urlencode "arg=$1" "$RPCURL=info" > "$tmpdir/$1.info"
  fi
}

pkginfo() {
  if ! [[ -f "$tmpdir/$1.PKGBUILD" ]]; then
    remote_folder=$(echo ${1} | cut -c -2)
    curl -Lfs "$PKGURL/$remote_folder/$1/$1/PKGBUILD" > "$tmpdir/$1.PKGBUILD"
  fi
}

# Checks if package is newer on ccr ($1 is package name, $2 is local version)
ccrversionisnewer() {
  rpcinfo "$1"
  unset ccrversion
  if existsinccr "$1"; then
    ccrversion="$(jshon -Q -e results -e Version -u < "$tmpdir/$1.info")"
    if [[ "$(LC_ALL=C vercmp "$ccrversion" "$2")" -gt 0  ]]; then
      return 0
    fi
  fi
  return 1
}

isoutofdate() {
  rpcinfo "$1"
  [[ "$(jshon -Q -e results -e OutOfDate -u < "$tmpdir/$1.info")" = "1" ]]
}

# $1 is prompt, $2 is file
confirm_edit() {
  if [[ (! -f "$2") || "$noconfirm" || "$noedit" ]]; then
    return
  fi
  echo -en "$1"
  if proceed; then
    ${EDITOR:-vi} "$2"
  fi
}

# Installs packages from ccr ($1 is package, $2 is dependency or explicit)
ccrinstall() {
  dir="${TMPDIR:-/tmp}/ccrbuild-$UID/$1"

  # Prepare the installation directory
  # If there is an old directory and ccrversion is not newer, use old directory
  if . "$dir/$1/PKGBUILD" &>/dev/null && ! ccrversionisnewer "$1" "$pkgver-$pkgrel"; then
    cd "$dir/$1"
  else
    [[ -d $dir ]] && rm -rf $dir
    mkdir -p "$dir"
    cd "$dir"
    remote_folder=$(echo ${1} | cut -c -2)
    curl -Lfs "$PKGURL/$remote_folder/$1/$1.tar.gz" > "$1.tar.gz"
    echo "uRL: $PKGURL/$remote_folder/$1/$1.tar.gz"
    tar xf "$1.tar.gz"
    cd "$1"

    # customizepkg
    if [[ -f "/etc/customizepkg.d/$1" ]] && type -t customizepkg &>/dev/null; then
      echo "Applying customizepkg instructions..."
      customizepkg --modify
    fi
  fi

  # Allow user to edit PKGBUILD
  confirm_edit "${COLOR6}Edit $1 PKGBUILD with \$EDITOR? [Y/n]${ENDCOLOR} " PKGBUILD
  if ! [[ -f PKGBUILD ]]; then
    err "No PKGBUILD found in directory."
  fi

  # Allow user to edit .install
  unset install
  . PKGBUILD
  confirm_edit "${COLOR6}Edit $install with \$EDITOR? [Y/n]${ENDCOLOR} " "$install"

  # Installation (makepkg and pacman)
  if [[ $UID -eq 0 ]]; then
    makepkg $MAKEPKGOPTS --asroot -f
  else
    makepkg $MAKEPKGOPTS -f
  fi

  [[ $? -ne 0 ]] && echo "The build failed." && return 1
  if  [[ $2 = dependency ]]; then
    runasroot pacman ${PACOPTS[@]} --asdeps -U $pkgname-*$PKGEXT
  elif [[ $2 = explicit ]]; then
    runasroot pacman ${PACOPTS[@]} -U $pkgname-*$PKGEXT
  fi
}

# Goes through all of the install tests and execution ($@ is packages to be installed)
installhandling() {
  packageargs=("$@")
  getignoredpackages
  sourcemakepkgconf
  # Figure out all of the packages that need to be installed
  for package in "${packageargs[@]}"; do
    # Determine whether package is in pacman repos
    if ! [[ $ccronly ]] && existsinpacman "$package"; then
      pacmanpackages+=("$package")
    elif ! [[ $ccronly ]] && existsinpacmangroup "$package"; then
      pacmanpackages+=("$package")
    elif existsinccr "$package"; then
      if finddeps "$package"; then
        # here is where dep dupes are created
        ccrpackages+=("$package")
        ccrdepends=("${ccrdeps[@]}" "${ccrdepends[@]}")
        pacmandepends+=("${pacmandeps[@]}")
      fi
    else
      err "Package \`$package' does not exist."
    fi
  done

  # Check if any ccr target packages are ignored
  for package in "${ccrpackages[@]}"; do
    if isignored "$package"; then
      echo -ne "${COLOR5}:: ${COLOR1}$package is in IgnorePkg/IgnoreGroup. Install anyway?${ENDCOLOR} [Y/n] "
      if [[ -z "$noconfirm" && $(! proceed) ]]; then
        continue
      fi
    fi
    ccrtargets+=("$package")
  done

  # Check if any ccr dependencies are ignored
  for package in "${ccrdepends[@]}"; do
    if isignored "$package"; then
      echo -ne "${COLOR5}:: ${COLOR1}$package is in IgnorePkg/IgnoreGroup. Install anyway?${ENDCOLOR} [Y/n] "
      if [[ -z "$noconfirm" && $(! proceed) ]]; then
          echo "Unresolved dependency \`$package'"
          unset ccrtargets
          break
      fi
    fi
  done
 
  # First install the explicit pacman packages, let pacman prompt
  if [[ $pacmanpackages ]]; then
    runasroot pacman "${PACOPTS[@]}" -S -- "${pacmanpackages[@]}"
  fi
  if [[ -z $ccrtargets ]]; then
    exit
  fi
  # Test if ccrpackages are already installed; echo warning if so
  for pkg in "${ccrtargets[@]}"; do
    if existsinlocal "$pkg"; then
      localversion="$(pacman -Qs "$pkg" | grep -F "local/$pkg" | cut -d ' ' -f 2)"
      if ! ccrversionisnewer "$pkg" "$localversion"; then
        echo -e "${COLOR6}warning:$ENDCOLOR $pkg-$localversion is up to date -- reinstalling"
      fi
    fi
  done

  # Echo warning if packages are out of date
  for pkg in "${ccrtargets[@]}" "${ccrdepends[@]}"; do
    if isoutofdate "$pkg"; then
      echo -e "${COLOR6}warning:$ENDCOLOR $pkg is flagged out of date"
    fi
  done
    
  # Prompt for ccr packages and their dependencies
  echo
  if [[ $ccrdepends ]]; then
    num="$((${#ccrdepends[@]}+${#ccrtargets[@]}))"
    echo -e "${COLOR6}Ccr Targets    ($num):${ENDCOLOR} ${ccrdepends[@]} ${ccrtargets[@]}"
  else 
    echo -e "${COLOR6}Ccr Targets    ($((${#ccrtargets[@]}))):${ENDCOLOR} ${ccrtargets[@]}"
  fi
  if [[ $pacmandepends ]]; then
    IFS=$'\n'
    pacmandepends=( $(printf "%s\n" "${pacmandepends[@]}" | sort -u) )
    echo -e "${COLOR6}Pacman Targets (${#pacmandepends[@]}):${ENDCOLOR} ${pacmandepends[@]}"
  fi

  # Prompt to proceed
  echo -en "\nProceed with installation? [Y/n] "
  if ! [[ $noconfirm ]]; then
    proceed || exit
  else
    echo
  fi

  # Install pacman dependencies
  if [[ $pacmandepends ]]; then
    runasroot pacman --noconfirm --asdeps -S -- "${pacmandepends[@]}" || err "Installation failed."
  fi 

  # Install ccr dependencies
  if [[ $ccrdepends ]]; then
    for dep in "${ccrdepends[@]}"; do
      ccrinstall "$dep" "dependency"
    done
  fi 

  # Install the ccr packages
  for package in "${ccrtargets[@]}"; do
    scrapeccrdeps "$package"
    if pacman -T "${dependencies[@]}" &>/dev/null; then
      ccrinstall "$package" "explicit"
    else
      echo "Dependencies for \`$package' are not met, not building..."
    fi
  done
}

urlencode() {
    echo $@ | LANG=C awk '
        BEGIN {
            split ("1 2 3 4 5 6 7 8 9 A B C D E F", hextab, " ")
            hextab [0] = 0
            for ( i=1; i<=255; ++i ) ord [ sprintf ("%c", i) "" ] = i + 0
        }
        {
            encoded = ""
            for ( i=1; i<=length ($0); ++i ) {
                c = substr ($0, i, 1)
                if ( c ~ /[a-zA-Z0-9.-]/ ) {
                    encoded = encoded c             # safe character
                } else if ( c == " " ) {
                    encoded = encoded "+"   # special handling
                } else {
                    # unsafe character, encode it as a two-digit hex-number
                    lo = ord [c] % 16
                    hi = int (ord [c] / 16);
                    encoded = encoded "%" hextab [hi] hextab [lo]
                }
            }
                print encoded
        }
        END {
        }
    '
}

login() {
    getcred

    while [[ -z $user ]]; do read -p "please enter your CCR username: " user; done
    while [[ -z $pass ]]; do read -p "please enter your CCR password: " -s pass && echo; done

    # logins to ccr and keeps session alive
    umask 077
    curl -Ss --cookie-jar "$tempdir/cjar" --output /dev/null ${ccrbaseurl} 
    curl -Ss --cookie "$tempdir/cjar" --cookie-jar "$tempdir/cjar"  \
    --data "user=$user" --data "passwd=$(urlencode $pass)" \
    --location --output "$tempdir/ccrvote.login"  \
      ${ccrbaseurl}
    if grep --quiet "'error'>Bad username or password" "$tempdir/ccrvote.login";then
        echo "incorrect password: check $configrc file"
        die 1
    fi
}
