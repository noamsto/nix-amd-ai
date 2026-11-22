# The models this module registers in lemond, described the way a client needs
# them: id, the context window they are served at, lemond's labels, and the
# input modalities they accept.
#
# The module renders `lemonade.customModels.*.labels` from this file, and a
# consumer renders its client-side model list from the same function, given the
# same `hardware.amd-npu.strata` settings. One implementation, so a client
# cannot claim a capability the server does not have — or, as happened with
# halo's pi (which listed the Strata model as text-only while `--vision` served
# images), miss one it does.
#
# Reachable as `inputs.nix-amd-ai.lib.modelCatalog`. Settings the module would
# default can be omitted: `defaults` below holds the values its option defaults
# read, so the two cannot disagree.
{lib}: let
  defaults = {
    modelName = "Qwen3.8-Flash-Next-Strata";
    contextSize = 131072;
    vision = true;
  };
in {
  inherit defaults;

  # `strata` is the module's option subtree, or the fragment of it a consumer
  # declares. Returns an attrset keyed by model id.
  modelCatalog = {strata}: let
    enabled = strata.enable or false;
    modelName = strata.modelName or defaults.modelName;
    vision = (strata.vision or {}).enable or defaults.vision;
    labels = ["chat" "reasoning" "tool-calling"] ++ lib.optional vision "vision";
  in
    lib.optionalAttrs enabled {
      ${modelName} = {
        contextWindow = strata.contextSize or defaults.contextSize;
        inherit labels;
        inputs = ["text"] ++ lib.optional vision "image";
      };
    };
}
