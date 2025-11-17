module

public import LeanScout

namespace LeanScout.CLI

open Lean

abbrev Command := String

structure Options where
  scoutPath : System.FilePath := "."
  target : Option Target := none
  command : Option Command := none
  schemaOnly : Bool := false

abbrev M := ReaderT Options IO

def getCommand : M Command := do
  match ← read <&> Options.command with
  | some cmd => return cmd
  | none => throw <| .userError "No command specified. Use --command"

def getTarget : M Target := do
  match ← read <&> Options.target with
  | some tgt => return tgt
  | none => throw <| .userError "No target specified. Use --imports or --read"

def getSchemaOnly : M Bool := read <&> Options.schemaOnly

def processArgs (args : List String) (opts : Options) : Options :=
  match args with
  | "--scoutPath" :: path :: args => processArgs args { opts with scoutPath := path }
  | "--command" :: command :: args => processArgs args { opts with command := some command }
  | "--schema" :: args => processArgs args { opts with schemaOnly := true }
  | "--read" :: [path] => { opts with target := some <| .read path {} }
  | "--imports" :: importsList => { opts with target := some <| .mkImports importsList.toArray {} }
  | _ => opts

def run (args : List String) (go : M α) : IO α := go <| processArgs args {}

unsafe
def main : M UInt32 := do
  let command ← getCommand
  let dataExtractors := data_extractors

  -- Handle "extractors" command (list available extractors)
  if command == "extractors" then
    for (e, _) in dataExtractors do
      println! e
    return 0

  -- Get the requested extractor
  let some extractor := dataExtractors.get? command.toName
    | throw <| .userError s!"Unknown command: {command}"

  -- Handle --schema flag (output schema with key and exit)
  if ← getSchemaOnly then
    let schemaJson := extractor.schema.toJson
    let fieldsJson := schemaJson.getObjValAs? (Array Json) "fields" |>.toOption.getD #[]
    let schemaWithKey : Json := json% {
      fields : $(fieldsJson),
      key : $(extractor.key)
    }
    IO.println schemaWithKey.compress
    return 0

  -- Run the extractor and write JSON lines to stdout
  let tgt ← getTarget
  let stdout ← IO.getStdout
  extractor.go (fun j => stdout.putStrLn j.compress) tgt
  return 0

end LeanScout.CLI

open LeanScout

public unsafe def main (args : List String) := do
  LeanScout.CLI.run args LeanScout.CLI.main
