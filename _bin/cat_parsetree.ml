let () =
  let filename = Sys.argv.(1) in
  if Filename.check_suffix filename ".mli" then begin
    let signature = Pparse.read_ast Pparse.Signature filename in
    Format.printf "%a@." Pprintast.signature signature
  end else begin
    let structure = Pparse.read_ast Pparse.Structure filename in
    Format.printf "%a@." Pprintast.structure structure
  end
