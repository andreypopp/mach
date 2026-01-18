export TERM=dumb
export MACH_HOME="$PWD"
cat > Mach << 'EOF'
build-backend "make"
EOF
