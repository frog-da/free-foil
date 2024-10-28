// File generated by the BNF Converter (bnfc 2.9.6).

package org.syntax.lambdapi.simple;

/** Abstract Visitor */

public class AbstractVisitor<R,A> implements AllVisitor<R,A> {
    /* Program */
    public R visit(org.syntax.lambdapi.simple.Absyn.AProgram p, A arg) { return visitDefault(p, arg); }
    public R visitDefault(org.syntax.lambdapi.simple.Absyn.Program p, A arg) {
      throw new IllegalArgumentException(this.getClass().getName() + ": " + p);
    }
    /* Command */
    public R visit(org.syntax.lambdapi.simple.Absyn.CommandCheck p, A arg) { return visitDefault(p, arg); }
    public R visit(org.syntax.lambdapi.simple.Absyn.CommandCompute p, A arg) { return visitDefault(p, arg); }
    public R visitDefault(org.syntax.lambdapi.simple.Absyn.Command p, A arg) {
      throw new IllegalArgumentException(this.getClass().getName() + ": " + p);
    }
    /* Term */
    public R visit(org.syntax.lambdapi.simple.Absyn.Lam p, A arg) { return visitDefault(p, arg); }
    public R visit(org.syntax.lambdapi.simple.Absyn.Pi p, A arg) { return visitDefault(p, arg); }
    public R visit(org.syntax.lambdapi.simple.Absyn.App p, A arg) { return visitDefault(p, arg); }
    public R visit(org.syntax.lambdapi.simple.Absyn.Var p, A arg) { return visitDefault(p, arg); }
    public R visitDefault(org.syntax.lambdapi.simple.Absyn.Term p, A arg) {
      throw new IllegalArgumentException(this.getClass().getName() + ": " + p);
    }

}