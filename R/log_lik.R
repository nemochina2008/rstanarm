# Part of the rstanarm package for estimating model parameters
# Copyright (C) 2015, 2016, 2017 Trustees of Columbia University
#
# This program is free software; you can redistribute it and/or
# modify it under the terms of the GNU General Public License
# as published by the Free Software Foundation; either version 3
# of the License, or (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program; if not, write to the Free Software
# Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA  02110-1301, USA.

#' Pointwise log-likelihood matrix
#'
#' For models fit using MCMC only, the \code{log_lik} method returns the
#' \eqn{S} by \eqn{N} pointwise log-likelihood matrix, where \eqn{S} is the size
#' of the posterior sample and \eqn{N} is the number of data points.
#'
#' @aliases log_lik
#' @export
#'
#' @templateVar stanregArg object
#' @template args-stanreg-object
#' @template args-dots-ignored
#' @param newdata An optional data frame of new data (e.g. holdout data) to use
#'   when evaluating the log-likelihood. See the description of \code{newdata}
#'   for \code{\link{posterior_predict}}.
#' @param offset A vector of offsets. Only required if \code{newdata} is
#'   specified and an \code{offset} was specified when fitting the model.
#'
#' @return An \eqn{S} by \eqn{N} matrix, where \eqn{S} is the size of the
#'   posterior sample and \eqn{N} is the number of data points.
#'   
#'   
#' @examples 
#' \donttest{
#'  roaches$roach100 <- roaches$roach1 / 100
#'  fit <- stan_glm(
#'     y ~ roach100 + treatment + senior,
#'     offset = log(exposure2),
#'     data = roaches,
#'     family = poisson(link = "log"),
#'     prior = normal(0, 2.5),
#'     prior_intercept = normal(0, 10),
#'     iter = 500 # to speed up example
#'  )
#'  ll <- log_lik(fit)
#'  dim(ll)
#'  all.equal(ncol(ll), nobs(fit))
#'
#'  # using newdata argument
#'  nd <- roaches[1:2, ]
#'  nd$treatment[1:2] <- c(0, 1)
#'  ll2 <- log_lik(fit, newdata = nd, offset = c(0, 0))
#'  head(ll2)
#'  dim(ll2)
#'  all.equal(ncol(ll2), nrow(nd))
#' }
#'
log_lik.stanreg <- function(object, newdata = NULL, offset = NULL, ...) {
  if (!used.sampling(object))
    STOP_sampling_only("Pointwise log-likelihood matrix")
  newdata <- validate_newdata(newdata)
  calling_fun <- as.character(sys.call(-1))[1]
  args <- ll_args(object, newdata = newdata, offset = offset, 
                  reloo_or_kfold = calling_fun %in% c("kfold", "reloo"), 
                  ...)
  fun <- ll_fun(object)
  if (is_clogit(object)) {
    out <-
      vapply(
        seq_len(args$N),
        FUN.VALUE = numeric(length = args$S),
        FUN = function(i) {
          as.vector(fun(
            i = i,
            draws = args$draws,
            data = args$data[args$data$strata ==
                               levels(args$data$strata)[i], , drop = FALSE]
          ))
        }
      )
    return(out)
  }
  
  out <- vapply(
    seq_len(args$N),
    FUN = function(i) {
      as.vector(fun(
        i = i,
        data = args$data[i, , drop = FALSE],
        draws = args$draws
      ))
    },
    FUN.VALUE = numeric(length = args$S)
  )
  colnames(out) <- if (is.null(newdata)) 
    rownames(model.frame(object)) else rownames(newdata)
  
  return(out)
}


# internal ----------------------------------------------------------------

# get log likelihood function for a particular model
# @param x stanreg object
# @return a function
ll_fun <- function(x) {
  validate_stanreg_object(x)
  if (is_polr(x) || is_scobit(x))
    return(.ll_polr_i)
  else if (is_clogit(x)) 
    return(.ll_clogit_i)
  else if (is.nlmer(x)) 
    return(.ll_nlmer_i)
  
  fun <- paste0(".ll_", family(x)$family, "_i")
  get(fun, mode = "function")
}

# get arguments needed for ll_fun
# @param object stanreg object
# @param newdata same as posterior predict
# @param offset vector of offsets (only required if model has offset term and
#   newdata is specified)
# @param reloo_or_kfold logical. TRUE if ll_args is for reloo or kfold
# @param ... For models without group-specific terms (i.e., not stan_[g]lmer), 
#   if reloo_or_kfold is TRUE and 'newdata' is specified then ... is used to 
#   pass 'newx' and 'stanmat' from reloo or kfold (bypassing pp_data). This is a
#   workaround in case there are issues with newdata containing factors with
#   only a single level.
# @return a named list with elements data, draws, S (posterior sample size) and
#   N = number of observations
ll_args <- function(object, newdata = NULL, offset = NULL, 
                    reloo_or_kfold = FALSE, ...) {
  validate_stanreg_object(object)
  f <- family(object)
  draws <- nlist(f)
  has_newdata <- !is.null(newdata)
  
  if (has_newdata && reloo_or_kfold && !is.mer(object)) {
    dots <- list(...)
    x <- dots$newx
    stanmat <- dots$stanmat
    y <- eval(formula(object)[[2L]], newdata)
  } else if (has_newdata) {
    ppdat <- pp_data(object, as.data.frame(newdata), offset = offset)
    tmp <- pp_eta(object, ppdat)
    eta <- tmp$eta
    stanmat <- tmp$stanmat
    x <- ppdat$x
    y <- eval(formula(object)[[2L]], newdata)
  } else {
    stanmat <- as.matrix.stanreg(object)
    x <- get_x(object)
    y <- get_y(object)
  }
  
  if (!is_polr(object)) { # not polr or scobit model
    fname <- f$family
    if (is.nlmer(object)) {
      draws <- list(mu = posterior_linpred(object, newdata = newdata),
                    sigma = stanmat[,"sigma"])
      data <- data.frame(y)
      data$offset <- if (has_newdata) offset else object$offset
      if (model_has_weights(object))
        data$weights <- object$weights
      return(nlist(data, draws, S = NROW(draws$mu), N = nrow(data)))
      
    } else if (!is.binomial(fname)) {
      data <- data.frame(y, x)
    } else {
      if (NCOL(y) == 2L) {
        trials <- rowSums(y)
        y <- y[, 1L]
      } else if (is_clogit(object)) {
        if (has_newdata) strata <- eval(object$call$strata, newdata)
        else strata <- model.frame(object)[,"(weights)"]
        strata <- as.factor(strata)
        successes <- aggregate(y, by = list(strata), FUN = sum)$x
        formals(draws$f$linkinv)$g <- strata
        formals(draws$f$linkinv)$successes <- successes
        trials <- 1L
      } else {
        trials <- 1
        if (is.factor(y)) 
          y <- fac2bin(y)
        stopifnot(all(y %in% c(0, 1)))
      }
      data <- data.frame(y, trials, x)
    }
    draws$beta <- stanmat[, seq_len(ncol(x)), drop = FALSE]
    if (is.gaussian(fname)) 
      draws$sigma <- stanmat[, "sigma"]
    if (is.gamma(fname)) 
      draws$shape <- stanmat[, "shape"]
    if (is.ig(fname)) 
      draws$lambda <- stanmat[, "lambda"]
    if (is.nb(fname)) 
      draws$size <- stanmat[,"reciprocal_dispersion"]
    if (is.beta(fname)) {
      draws$f_phi <- object$family_phi
      z_vars <- colnames(stanmat)[grepl("(phi)", colnames(stanmat))]
      if (length(z_vars) == 1 && z_vars == "(phi)") {
        draws$phi <- stanmat[, z_vars]
      } else {
        x_dat <- get_x(object)
        z_dat <- object$z
        colnames(x_dat) <- colnames(x_dat)
        colnames(z_dat) <- paste0("(phi)_", colnames(z_dat))
        data <- data.frame(y = get_y(object), cbind(x_dat, z_dat), check.names = FALSE)
        draws$phi <- stanmat[,z_vars]
      }
    }
  } else {
    stopifnot(is_polr(object))
    y <- as.integer(y)
    if (has_newdata) 
      x <- .validate_polr_x(object, x)
    data <- data.frame(y, x)
    draws$beta <- stanmat[, colnames(x), drop = FALSE]
    patt <- if (length(unique(y)) == 2L) "(Intercept)" else "|"
    zetas <- grep(patt, colnames(stanmat), fixed = TRUE, value = TRUE)
    draws$zeta <- stanmat[, zetas, drop = FALSE]
    draws$max_y <- max(y)
    if ("alpha" %in% colnames(stanmat)) { 
      stopifnot(is_scobit(object))
      # scobit
      draws$alpha <- stanmat[, "alpha"]
      draws$f <- object$method
    }
  }
  
  data$offset <- if (has_newdata) offset else object$offset
  if (model_has_weights(object))
    data$weights <- object$weights
  
  if (is.mer(object)) {
    b <- stanmat[, b_names(colnames(stanmat)), drop = FALSE]
    if (has_newdata) {
      Z_names <- ppdat$Z_names
      if (is.null(Z_names)) {
        b <- b[, !grepl("_NEW_", colnames(b), fixed = TRUE), drop = FALSE]
      } else {
        b <- pp_b_ord(b, Z_names)
      }
      if (is.null(ppdat$Zt)) z <- matrix(NA, nrow = nrow(x), ncol = 0)
      else z <- t(ppdat$Zt)
    } else {
      z <- get_z(object)
    }
    data <- cbind(data, as.matrix(z)[1:NROW(x),, drop = FALSE])
    draws$beta <- cbind(draws$beta, b)
  }
  
  if (is_clogit(object)) {
    data$strata <- strata
    out <-nlist(data, draws, S = NROW(draws$beta), N = nlevels(strata))
  } else {
    out <- nlist(data, draws, S = NROW(draws$beta), N = nrow(data)) 
  }
  return(out)
}


# check intercept for polr models -----------------------------------------
# Check if a model fit with stan_polr has an intercept (i.e. if it's actually a 
# bernoulli model). If it doesn't have an intercept then the intercept column in
# x is dropped. This is only necessary if newdata is specified because otherwise
# the correct x is taken from the fitted model object.
.validate_polr_x <- function(object, x) {
  x0 <- get_x(object)
  has_intercept <- colnames(x0)[1L] == "(Intercept)" 
  if (!has_intercept && colnames(x)[1L] == "(Intercept)")
    x <- x[, -1L, drop = FALSE]
  x
}


# log-likelihood function helpers -----------------------------------------
.weighted <- function(val, w) {
  if (is.null(w)) {
    val
  } else {
    val * w
  } 
}

.xdata <- function(data) {
  sel <- c("y", "weights","offset", "trials","strata")
  data[, -which(colnames(data) %in% sel)]
}
.mu <- function(data, draws) {
  eta <- as.vector(linear_predictor(draws$beta, .xdata(data), data$offset))
  draws$f$linkinv(eta)
}

# for stan_betareg only
.xdata_beta <- function(data) { 
  sel <- c("y", "weights","offset", "trials")
  data[, -c(which(colnames(data) %in% sel), grep("(phi)_", colnames(data), fixed = TRUE))]
}
.zdata_beta <- function(data) {
  sel <- c("y", "weights","offset", "trials")
  data[, grep("(phi)_", colnames(data), fixed = TRUE)]
}
.mu_beta <- function(data, draws) {
  eta <- as.vector(linear_predictor(draws$beta, .xdata_beta(data), data$offset))
  draws$f$linkinv(eta)
}
.phi_beta <- function(data, draws) {
  eta <- as.vector(linear_predictor(draws$phi, .zdata_beta(data), data$offset))
  draws$f_phi$linkinv(eta)
}

# log-likelihood functions ------------------------------------------------
.ll_gaussian_i <- function(i, data, draws) {
  val <- dnorm(data$y, mean = .mu(data,draws), sd = draws$sigma, log = TRUE)
  .weighted(val, data$weights)
}
.ll_binomial_i <- function(i, data, draws) {
  val <- dbinom(data$y, size = data$trials, prob = .mu(data,draws), log = TRUE)
  .weighted(val, data$weights)
}
.ll_clogit_i <- function(i, data, draws) {
  eta <- linear_predictor(draws$beta, .xdata(data), data$offset)
  denoms <- apply(eta, 1, log_clogit_denom, N_j = NCOL(eta), D_j = sum(data$y))
  rowSums(eta[,data$y == 1, drop = FALSE] - denoms)
}
.ll_poisson_i <- function(i, data, draws) {
  val <- dpois(data$y, lambda = .mu(data, draws), log = TRUE)
  .weighted(val, data$weights)
}
.ll_neg_binomial_2_i <- function(i, data, draws) {
  val <- dnbinom(data$y, size = draws$size, mu = .mu(data, draws), log = TRUE)
  .weighted(val, data$weights)
}
.ll_Gamma_i <- function(i, data, draws) {
  val <- dgamma(data$y, shape = draws$shape, 
                rate = draws$shape / .mu(data,draws), log = TRUE)
  .weighted(val, data$weights)
}
.ll_inverse.gaussian_i <- function(i, data, draws) {
  mu <- .mu(data, draws)
  val <- 0.5 * log(draws$lambda / (2 * pi)) - 
    1.5 * log(data$y) -
    0.5 * draws$lambda * (data$y - mu)^2 / 
    (data$y * mu^2)
  .weighted(val, data$weights)
}
.ll_polr_i <- function(i, data, draws) {
  eta <- linear_predictor(draws$beta, .xdata(data), data$offset)
  f <- draws$f
  J <- draws$max_y
  y_i <- data$y
  linkinv <- polr_linkinv(f)
  if (is.null(draws$alpha)) {
    if (y_i == 1) {
      val <- log(linkinv(draws$zeta[, 1] - eta))
    } else if (y_i == J) {
      val <- log1p(-linkinv(draws$zeta[, J-1] - eta))
    } else {
      val <- log(linkinv(draws$zeta[, y_i] - eta) - 
                   linkinv(draws$zeta[, y_i - 1L] - eta))
    }
  } else {
    if (y_i == 0) {
      val <- draws$alpha * log(linkinv(draws$zeta[, 1] - eta))
    } else if (y_i == 1) {
      val <- log1p(-linkinv(draws$zeta[, 1] - eta) ^ draws$alpha)
    } else {
      stop("Exponentiation only possible when there are exactly 2 outcomes.")
    }
  }
  .weighted(val, data$weights)
}
.ll_beta_i <- function(i, data, draws) {
  mu <- .mu_beta(data, draws)
  phi <- draws$phi
  if (length(grep("(phi)_", colnames(data), fixed = TRUE)) > 0) {
    phi <- .phi_beta(data, draws)
  }
  val <- dbeta(data$y, mu * phi, (1 - mu) * phi, log = TRUE)
  .weighted(val, data$weights)
}
.ll_nlmer_i <- function(i, data, draws) {
  val <- dnorm(data$y, mean = draws$mu[,i], sd = draws$sigma, log = TRUE)
  .weighted(val, data$weights)
}
