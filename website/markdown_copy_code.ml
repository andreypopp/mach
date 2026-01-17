#!/usr/bin/env mach run
#require "cmarkit"
(* Add copy-to-clipboard buttons to code blocks *)

let copy_script = {|<script>
function copyCode(btn) {
  const codeBlock = btn.parentElement.querySelector('pre code');
  if (codeBlock) {
    let text = codeBlock.textContent;
    if (codeBlock.classList.contains('language-sh') || codeBlock.classList.contains('language-bash')) {
      text = text.split('\n').map(line => line.replace(/^\$\s*/, '')).join('\n');
    }
    navigator.clipboard.writeText(text).then(() => {
      const originalText = btn.textContent;
      btn.textContent = 'done';
      setTimeout(() => { btn.textContent = originalText; }, 2000);
    });
  }
}
</script>|}

let code_block_renderer c cb =
  let open Cmarkit in
  let open Cmarkit_renderer.Context in
  string c {|<div class="code-block">|};
  string c copy_script;
  string c {|<button class="copy-btn" onclick="copyCode(this)" title="Copy to clipboard">copy</button>|};
  (* Render the pre/code block ourselves *)
  string c "<pre><code";
  (match Block.Code_block.info_string cb with
  | None -> ()
  | Some (info, _) ->
      match Block.Code_block.language_of_info_string info with
      | None -> ()
      | Some (lang, _) ->
          string c {| class="language-|};
          Cmarkit_html.html_escaped_string c lang;
          string c {|"|});
  string c ">";
  (* Render code lines *)
  let code_lines = Block.Code_block.code cb in
  List.iter (fun line ->
    let text, _ = line in
    Cmarkit_html.html_escaped_string c text;
    string c "\n"
  ) code_lines;
  string c "</code></pre>";
  string c {|</div>|};
  true

let renderer =
  let open Cmarkit in
  let block c = function
    | Block.Code_block (cb, _meta) -> code_block_renderer c cb
    | _ -> false
  in
  Cmarkit_renderer.make ~block ()

let copy_script = {|<script>
function copyCode(btn) {
  const codeBlock = btn.parentElement.querySelector('pre code');
  if (codeBlock) {
    let text = codeBlock.textContent;
    if (codeBlock.classList.contains('language-sh') || codeBlock.classList.contains('language-bash')) {
      text = text.split('\n').map(line => line.replace(/^\$\s*/, '')).join('\n');
    }
    navigator.clipboard.writeText(text).then(() => {
      const originalText = btn.textContent;
      btn.textContent = 'done';
      setTimeout(() => { btn.textContent = originalText; }, 2000);
    });
  }
}
</script>|}
