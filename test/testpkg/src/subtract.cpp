#include <R.h>
#include <Rinternals.h>

extern "C" SEXP subtract(SEXP a, SEXP b)
{
  SEXP result = PROTECT(Rf_allocVector(REALSXP, 1));
  REAL(result)[0] = Rf_asReal(a) - Rf_asReal(b);
  UNPROTECT(1);
  return result;
}
