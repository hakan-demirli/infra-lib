{ lib }:
let
  validateComments =
    comments:
    if builtins.isList comments && lib.all builtins.isString comments then
      comments
    else
      throw "hujson comments must be a list of strings";

  renderComment = line: if line == "" then "//" else "// ${line}";
in
rec {
  render =
    {
      value,
      comments ? [ ],
    }:
    let
      checkedComments = validateComments comments;
      header = lib.optionalString (checkedComments != [ ]) (
        lib.concatMapStringsSep "\n" renderComment checkedComments + "\n\n"
      );
    in
    header + builtins.toJSON value + "\n";

  write =
    {
      pkgs,
      name,
      value,
      comments ? [ ],
    }:
    if !builtins.isString name || !lib.hasSuffix ".hujson" name then
      throw "hujson output name must end in .hujson"
    else
      pkgs.writeText name (render {
        inherit value comments;
      });
}
