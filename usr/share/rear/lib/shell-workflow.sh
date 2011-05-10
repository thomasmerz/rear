WORKFLOW_shell_DESCRIPTION="Start a Bash within ReaR (development tool)"
WORKFLOWS=( "${WORKFLOWS[@]}" shell )                                           
WORKFLOW_shell () {
	for arg in "${ARGS[@]}" ; do
		key=OPT_"${arg%%=*}"
		val="${arg#*=}"
		declare $key="$val"
		Log "Setting $key=$val"
	done

	export REAR_EVAL="$(declare -p | sed -e 's/^declare .. //' -e '/MASKS=/d' )" 
	bash --rcfile $SHARE_DIR/lib/bashrc.rear -i 2>&1
	
}
