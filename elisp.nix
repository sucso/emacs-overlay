/*
Parse an emacs lisp configuration file to derive packages from
use-package declarations.
*/

{ pkgs }:
let
  parse = pkgs.callPackage ./parse.nix { };
  inherit (pkgs) lib;



in
{
# a list of config files to parse
  configs ? null
# config has been superseded by configs
, config ? null
# bool to use the value of config or a derivation whose name is default.el
, defaultInitFile ? false
# emulate `use-package-always-ensure` behavior (defaulting to false)
, alwaysEnsure ? false
# emulate `#+PROPERTY: header-args:emacs-lisp :tangle yes`
, alwaysTangle ? false
, extraEmacsPackages ? epkgs: [ ]
, package ? pkgs.emacs
, override ? (self: super: { })
}:
let
  # checks if a file is a .org file
  isOrgModeFile = config:
    let
      ext = lib.last (builtins.split "\\." (builtins.toString config));
      type = builtins.typeOf config;
    in
      (type == "path" || lib.hasPrefix "/" config) && ext == "org";

  # whether `configs` is just an org mode file
  isOrgModeConfig =
    let
      length = builtins.length configs;
      head = builtins.head configs;
    in
      (length == 1) && (isOrgModeFile head);

  getConfigText = config:
    let
      type = builtins.typeOf config;
    in # config texts can be sourced from a list of:
      # (mixing these types in a single `configs` attribute is allowed)
      # - strings with context { configs = [ "${hello}/config.el" "${world}/config.el" ]; }
      if type == "string" && builtins.hasContext config && lib.hasPrefix builtins.storeDir config then builtins.readFile config
      # - config literals { configs = [ "(use-package foo)" "(use-package bar)" ]; }
      else if type == "string" then config
      # - config paths { configs = [ ./init.el ./config.el ]; }
      else if type == "path" then builtins.readFile config
      # - derivations { configs = [ (pkgs.writeText "foo.el" "(use-package foo)")
      #                             (pkgs.writeText "bar.el" "(use-package bar)") ]; }
      else if lib.isDerivation config then builtins.readFile "${config}"
      else throw "Unsupported type for a member of configs: \"${type}\"";

  configTexts =
    let
      configNotice = "TODO";
      configError = "TODO";
      type = builtins.typeOf configs;
    in
    if config != null then lib.warn configNotice [config]
    else if configs != null then
      if (type != "list") then getConfigText configs
      else map getConfigText configs
    else builtins.throw configError;

  packages = parse.parsePackagesFromUsePackage {
    inherit configTexts isOrgModeConfig alwaysTangle alwaysEnsure;
  };
  emacsPackages = (pkgs.emacsPackagesFor package).overrideScope (self: super:
    # for backward compatibility: override was a function with one parameter
    if builtins.isFunction (override super)
    then override self super
    else override super
  );
  emacsWithPackages = emacsPackages.emacsWithPackages;
  mkPackageError = name:
    let
      errorFun = if (alwaysEnsure != null && alwaysEnsure) then builtins.trace else throw;
    in
    errorFun "Emacs package ${name}, declared wanted with use-package, not found." null;
in
emacsWithPackages (epkgs:
  let
    usePkgs = map (name: epkgs.${name} or (mkPackageError name)) packages;
    extraPkgs = extraEmacsPackages epkgs;
    defaultInitFilePkg =
      if !((builtins.isBool defaultInitFile) || (lib.isDerivation defaultInitFile))
      then throw "defaultInitFile must be bool or derivation"
      else
        if defaultInitFile == false
        then null
        else
          let
            # name of the default init file must be default.el according to elisp manual
            defaultInitFileName = "default.el";
            # config texts are concatenated following the order of the
            # list into a single init file
            configFile = pkgs.writeText defaultInitFileName (builtins.concatStringsSep "\n\n\n" configTexts);
            orgModeConfigFile = pkgs.runCommand defaultInitFileName {
              nativeBuildInputs = [ package ];
            } ''
              cp ${configFile} config.org
              emacs -Q --batch ./config.org -f org-babel-tangle
              mv config.el $out
            '';
          in
          epkgs.trivialBuild {
            pname = "default";
            src =
              if defaultInitFile == true
              then
                if isOrgModeConfig
                then orgModeConfigFile
                else configFile
              else
                if defaultInitFile.name == defaultInitFileName
                then defaultInitFile
                else throw "name of defaultInitFile must be ${defaultInitFileName}";
            version = "0.1.0";
            packageRequires = usePkgs ++ extraPkgs;
          };
  in
  usePkgs ++ extraPkgs ++ [ defaultInitFilePkg ])
