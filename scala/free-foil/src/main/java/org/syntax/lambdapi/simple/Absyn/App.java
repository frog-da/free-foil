// File generated by the BNF Converter (bnfc 2.9.6).

package org.syntax.lambdapi.simple.Absyn;

public class App  extends Term {
  public final Term term_1, term_2;
  public App(Term p1, Term p2) { term_1 = p1; term_2 = p2; }

  public <R,A> R accept(org.syntax.lambdapi.simple.Absyn.Term.Visitor<R,A> v, A arg) { return v.visit(this, arg); }

  public boolean equals(java.lang.Object o) {
    if (this == o) return true;
    if (o instanceof org.syntax.lambdapi.simple.Absyn.App) {
      org.syntax.lambdapi.simple.Absyn.App x = (org.syntax.lambdapi.simple.Absyn.App)o;
      return this.term_1.equals(x.term_1) && this.term_2.equals(x.term_2);
    }
    return false;
  }

  public int hashCode() {
    return 37*(this.term_1.hashCode())+this.term_2.hashCode();
  }


}
