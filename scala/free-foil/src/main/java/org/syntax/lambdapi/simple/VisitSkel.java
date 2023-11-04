// File generated by the BNF Converter (bnfc 2.9.6).

package org.syntax.lambdapi.simple;

/*** Visitor Design Pattern Skeleton. ***/

/* This implements the common visitor design pattern.
   Tests show it to be slightly less efficient than the
   instanceof method, but easier to use.
   Replace the R and A parameters with the desired return
   and context types.*/

public class VisitSkel
{
  public class ProgramVisitor<R,A> implements org.syntax.lambdapi.simple.Absyn.Program.Visitor<R,A>
  {
    public R visit(org.syntax.lambdapi.simple.Absyn.AProgram p, A arg)
    { /* Code for AProgram goes here */
      for (org.syntax.lambdapi.simple.Absyn.Command x: p.listcommand_) {
        x.accept(new CommandVisitor<R,A>(), arg);
      }
      return null;
    }
  }
  public class CommandVisitor<R,A> implements org.syntax.lambdapi.simple.Absyn.Command.Visitor<R,A>
  {
    public R visit(org.syntax.lambdapi.simple.Absyn.CommandCheck p, A arg)
    { /* Code for CommandCheck goes here */
      p.term_1.accept(new TermVisitor<R,A>(), arg);
      p.term_2.accept(new TermVisitor<R,A>(), arg);
      return null;
    }
    public R visit(org.syntax.lambdapi.simple.Absyn.CommandCompute p, A arg)
    { /* Code for CommandCompute goes here */
      p.term_1.accept(new TermVisitor<R,A>(), arg);
      p.term_2.accept(new TermVisitor<R,A>(), arg);
      return null;
    }
  }
  public class TermVisitor<R,A> implements org.syntax.lambdapi.simple.Absyn.Term.Visitor<R,A>
  {
    public R visit(org.syntax.lambdapi.simple.Absyn.Lam p, A arg)
    { /* Code for Lam goes here */
      //p.ident_;
      p.term_.accept(new TermVisitor<R,A>(), arg);
      return null;
    }
    public R visit(org.syntax.lambdapi.simple.Absyn.Pi p, A arg)
    { /* Code for Pi goes here */
      //p.ident_;
      p.term_1.accept(new TermVisitor<R,A>(), arg);
      p.term_2.accept(new TermVisitor<R,A>(), arg);
      return null;
    }
    public R visit(org.syntax.lambdapi.simple.Absyn.App p, A arg)
    { /* Code for App goes here */
      p.term_1.accept(new TermVisitor<R,A>(), arg);
      p.term_2.accept(new TermVisitor<R,A>(), arg);
      return null;
    }
    public R visit(org.syntax.lambdapi.simple.Absyn.Var p, A arg)
    { /* Code for Var goes here */
      //p.ident_;
      return null;
    }
  }
}
