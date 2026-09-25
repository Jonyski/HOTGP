-- |
-- Module      : Grammar
-- Description : Umbrella module re-exporting the whole grammar layer.
--
-- Importing "Grammar" gives you everything needed to build, check, evaluate
-- and print programs:
--
-- * "Grammar.Core"   - the AST ('Tree', 'Lit', 'Operation', 'GType');
-- * "Grammar.Types"  - signatures ('opType') and the type checker;
-- * "Grammar.Eval"   - the interpreter ('evalTree');
-- * "Grammar.Helpers"- constructors and the measure cache;
-- * "Grammar.Pretty" - 'Pretty' instances for grammar values.
--
-- "Grammar.Simplify" is deliberately /not/ re-exported: it is an optional
-- post-processing pass used only by "Prune" and a couple of tests, and
-- keeping it out of the umbrella import avoids name clutter.
module Grammar
  ( module Grammar.Core,
    module Grammar.Helpers,
    module Grammar.Pretty,
    module Grammar.Eval,
    module Grammar.Types,
  )
where

import Grammar.Core
import Grammar.Eval
import Grammar.Helpers
import Grammar.Pretty
import Grammar.Types
