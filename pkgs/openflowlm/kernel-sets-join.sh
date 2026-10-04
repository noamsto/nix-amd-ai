# Executes a kernel-sets-plan.sh plan. Sourced by the openflowlm-kernels join
# and by the openflowlm-kernel-sets-join flake check, which supplies stub
# copy_llm/copy_bert/build_llm/build_bert so the order logic runs without a
# kernel build.
#
# execute_plan PLAN DEST_XCLBINS: build_* leave their output in src/xclbins;
# it is copied over DEST_XCLBINS and the staging dir reset, so a later inline
# build cannot re-copy an earlier one over a COPY that ran in between.
execute_plan() {
  local plan=$1 dest=$2 action name
  while IFS=' ' read -r action name; do
    case "$action" in
      COPY-LLM) copy_llm "$name" ;;
      COPY-BERT) copy_bert "$name" ;;
      BUILD-LLM | BUILD-BERT)
        echo "WARNING: kernel set $name is present in src but missing from kernel-sets.json; building it in the join. Run pkgs/openflowlm/update-kernel-sets.sh to refresh the list." >&2
        "build_${action#BUILD-}" "$name"
        chmod -R u+w "$dest"
        cp -a src/xclbins/. "$dest"/
        rm -rf src/xclbins
        mkdir src/xclbins
        ;;
      SKIP-LLM | SKIP-BERT)
        echo "WARNING: kernel set $name is listed in kernel-sets.json but absent from src; skipping it. Run pkgs/openflowlm/update-kernel-sets.sh to refresh the list." >&2
        ;;
    esac
  done <"$plan"
}
