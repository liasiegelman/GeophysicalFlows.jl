"""
    test_bqgql_rossbywave(; kwargs...)

Evolvesa a Rossby wave and compares with the analytic solution.
"""
function test_bqgql_rossbywave(stepper, dt, nsteps)
    nx = 64
  beta = 2.0
    Lx = 2π
    mu = 0.0
    nu = 0.0

  # the following if statement is called so that all the cases of
  # Problem() fuction are tested
  if stepper=="ForwardEuler"
    eta = zeros(nx, nx)
  else
    eta(x, y) = 0*x
  end

  prob = BarotropicQGQL.InitialValueProblem(nx=nx, Lx=Lx, eta=eta, beta=beta, mu=mu, nu=nu, stepper=stepper, dt=dt)
  s, v, p, g = prob.state, prob.vars, prob.params, prob.grid

  # the Rossby wave initial condition
   ampl = 1e-2
  kwave = 3.0*2π/g.Lx
  lwave = 2.0*2π/g.Ly
      ω = -p.beta*kwave/(kwave^2.0 + lwave^2.0)
     ζ0 = ampl*cos.(kwave*g.X).*cos.(lwave*g.Y)
    ζ0h = rfft(ζ0)

  BarotropicQGQL.set_zeta!(prob, ζ0)

  stepforward!(prob, nsteps)
  dealias!(s.sol, g)
  BarotropicQGQL.updatevars!(prob)

  ζ_theory = ampl*cos.(kwave*(g.X .- ω/kwave*s.t)) .* cos.(lwave*g.Y)

  isapprox(ζ_theory, v.zeta, rtol=g.nx*g.ny*nsteps*1e-12)
end

"""
    test_stochasticforcingbudgets(; kwargs...)

Tests if the energy budgets are closed for BarotropicQG with stochastic forcing.
"""
function test_bqgql_stochasticforcingbudgets(; n=256, dt=0.01, L=2π, nu=1e-7, nnu=2, mu=1e-1, message=false)
  n, L  = 256, 2π
  nu, nnu = 1e-7, 2
  mu = 1e-1
  dt, tf = 0.005, 0.1/mu
  nt = round(Int, tf/dt)
  ns = 1

  # Forcing
  kf, dkf = 12.0, 2.0
  σ = 0.1
  gr  = TwoDGrid(n, L)

  force2k = zero(gr.Kr)
  @. force2k = exp.(-(sqrt(gr.KKrsq)-kf)^2/(2*dkf^2))
  @. force2k[gr.KKrsq .< 2.0^2 ] = 0
  @. force2k[gr.KKrsq .> 20.0^2 ] = 0
  @. force2k[gr.Kr .< 2π/L] = 0
  σ0 = parsevalsum(force2k.*gr.invKKrsq/2.0, gr)/(gr.Lx*gr.Ly)
  force2k .= σ/σ0 * force2k

  Random.seed!(1234)

  function calcF!(F, t, s, v, p, g)
    eta = exp.(2π*im*rand(Float64, size(s.sol)))/sqrt(s.dt)
    eta[1, 1] = 0
    @. F = eta .* sqrt(force2k)
    nothing
  end

  prob = BarotropicQGQL.ForcedProblem(nx=n, Lx=L, nu=nu, nnu=nnu, mu=mu, dt=dt,
   stepper="RK4", calcF=calcF!, stochastic=true)

  s, v, p, g, eq, ts = prob.state, prob.vars, prob.params, prob.grid, prob.eqn, prob.ts

  BarotropicQGQL.set_zeta!(prob, 0*g.X)
  E = Diagnostic(BarotropicQGQL.energy,      prob, nsteps=nt)
  D = Diagnostic(BarotropicQGQL.dissipation, prob, nsteps=nt)
  R = Diagnostic(BarotropicQGQL.drag,        prob, nsteps=nt)
  W = Diagnostic(BarotropicQGQL.work,        prob, nsteps=nt)
  diags = [E, D, W, R]

  # Step forward

  stepforward!(prob, diags, round(Int, nt))

  BarotropicQGQL.updatevars!(prob)

  cfl = prob.ts.dt*maximum([maximum(v.v)/g.dx, maximum(v.u)/g.dy])

  E, D, W, R = diags

  t = round(mu*prob.state.t, digits=2)

  i₀ = 1
  dEdt = (E[(i₀+1):E.count] - E[i₀:E.count-1])/prob.ts.dt
  ii = (i₀):E.count-1
  ii2 = (i₀+1):E.count

  # dEdt = W - D - R?
  # If the Ito interpretation was used for the work
  # then we need to add the drift term
  # total = W[ii2]+σ - D[ii] - R[ii]      # Ito
  total = W[ii2] - D[ii] - R[ii]        # Stratonovich

  residual = dEdt - total

  if message
    println("step: %04d, t: %.1f, cfl: %.3f, time: %.2f s\n", prob.step, prob.t, cfl, tc)
  end
  # println(mean(abs.(residual)))
  isapprox(mean(abs.(residual)), 0, atol=1e-4)
end

"""
    test_stochasticforcingbudgets(; kwargs...)

Tests if the energy budgets are closed for BarotropicQG with stochastic forcing.
"""
function test_bqgql_deterministicforcingbudgets(; n=256, dt=0.01, L=2π, nu=1e-7, nnu=2, mu=1e-1, message=false)
  n, L  = 256, 2π
  nu, nnu = 1e-7, 2
  mu = 1e-1
  dt, tf = 0.005, 0.1/mu
  nt = round(Int, tf/dt)
  ns = 1


  # Forcing = 0.01cos(4x)cos(5y)cos(2t)
  gr  = TwoDGrid(n, L)
  f = @. 0.01*cos(4*gr.kr[2]*gr.X)*cos(5*gr.l[2]*gr.Y)
  fh = rfft(f)
  function calcF!(Fh, t, s, v, p, g)
    @. Fh = fh*cos(2*t)
    nothing
  end

  prob = BarotropicQGQL.ForcedProblem(nx=n, Lx=L, nu=nu, nnu=nnu, mu=mu, dt=dt,
   stepper="RK4", calcF=calcF!, stochastic=false)

  s, v, p, g, eq, ts = prob.state, prob.vars, prob.params, prob.grid, prob.eqn, prob.ts;

  BarotropicQGQL.set_zeta!(prob, 0*g.X)
  E = Diagnostic(BarotropicQGQL.energy,      prob, nsteps=nt)
  D = Diagnostic(BarotropicQGQL.dissipation, prob, nsteps=nt)
  R = Diagnostic(BarotropicQGQL.drag,        prob, nsteps=nt)
  W = Diagnostic(BarotropicQGQL.work,        prob, nsteps=nt)
  diags = [E, D, W, R]

  # Step forward

  stepforward!(prob, diags, round(Int, nt))

  BarotropicQGQL.updatevars!(prob)

  cfl = prob.ts.dt*maximum([maximum(v.v)/g.dx, maximum(v.u)/g.dy])

  E, D, W, R = diags

  t = round(mu*prob.state.t, digits=2)

  i₀ = 1
  dEdt = (E[(i₀+1):E.count] - E[i₀:E.count-1])/prob.ts.dt
  ii = (i₀):E.count-1
  ii2 = (i₀+1):E.count

  # dEdt = W - D - R?
  total = W[ii2] - D[ii] - R[ii]

  residual = dEdt - total

  if message
    println("step: %04d, t: %.1f, cfl: %.3f, time: %.2f s\n", prob.step, prob.t, cfl, tc)
  end
  # println(mean(abs.(residual)))
  isapprox(mean(abs.(residual)), 0, atol=1e-8)
end

"""
    test_bqgql_nonlinearadvection(dt, stepper; kwargs...)

Tests the advection term in the twodturb module by timestepping a
test problem with timestep dt and timestepper identified by the string stepper.
The test problem is derived by picking a solution ζf (with associated
streamfunction ψf) for which the advection term J(ψf, ζf) is non-zero. Next, a
forcing Ff is derived according to Ff = ∂ζf/∂t + J(ψf, ζf) - nuΔζf. One solution
to the vorticity equation forced by this Ff is then ζf. (This solution may not
be realized, at least at long times, if it is unstable.)
"""
function test_bqgql_advection(dt, stepper; n=128, L=2π, nu=1e-2, nnu=1, mu=0.0, message=false)
  n, L  = 128, 2π
  nu, nnu = 1e-2, 1
  mu = 0.0
  tf = 1.0
  nt = round(Int, tf/dt)

  gr  = TwoDGrid(n, L)
  x, y = gr.X, gr.Y

  psif =    cos.(3y) +  sin.(2x).*cos.(2y) +  2sin.(x).*cos.(3y)
    qf = - 9cos.(3y) - 8sin.(2x).*cos.(2y) - 20sin.(x).*cos.(3y)

  Ff = nu*( 81cos.(3y) .+ 200cos.(3y).*sin.(x) .+ 64cos.(2y).*sin.(2x) ) -
    3sin.(3y).*(-16cos.(2x).*cos.(2y) .- 20cos.(x).*cos.(3y)) .-
 27sin.(3y).*(2cos.(2x).*cos.(2y) .+ 2cos.(x).*cos.(3y)) .+ 0*(-8cos.(x).*cos.(3y).*sin.(2x).*sin(2y) +
 24*cos.(2x).*cos.(2y).*sin.(x).*sin.(3y))


  Ffh = -rfft(Ff)

  # Forcing
  function calcF!(Fh, t, s, v, p, g)
    Fh .= Ffh
    nothing
  end

  prob = BarotropicQGQL.ForcedProblem(nx=n, Lx=L, nu=nu, nnu=nnu, mu=mu, dt=dt, stepper=stepper, calcF=calcF!)
  s, v, p, g, eq, ts = prob.state, prob.vars, prob.params, prob.grid, prob.eqn, prob.ts
  BarotropicQGQL.set_zeta!(prob, qf)

  # Step forward
  stepforward!(prob, round(Int, nt))
  BarotropicQGQL.updatevars!(prob)
  isapprox(v.zeta+v.Zeta, qf, rtol=1e-13)
end

function test_bqgql_energyenstrophy()
  nx, Lx  = 64, 2π
  ny, Ly  = 64, 3π
  g  = TwoDGrid(nx, Lx, ny, Ly)
  k0 = g.k[2] # fundamental wavenumber
  l0 = g.l[2] # fundamental wavenumber
  x, y = g.X, g.Y

    eta = @. cos(10*k0*x)*cos(10*l0*y)
   psi0 = @. sin(2*k0*x)*cos(2*l0*y) + 2sin(k0*x)*cos(3*l0*y)
  zeta0 = @. -((2*k0)^2+(2*l0)^2)*sin(2*k0*x)*cos(2*l0*y) - (k0^2+(3*l0)^2)*2sin(k0*x)*cos(3*l0*y)

  prob = BarotropicQGQL.InitialValueProblem(nx=nx, Lx=Lx, ny=ny, Ly=Ly, eta = eta, stepper="ForwardEuler")
  s, v, p, g, eq, ts = prob.state, prob.vars, prob.params, prob.grid, prob.eqn, prob.ts
  BarotropicQGQL.set_zeta!(prob, zeta0)
  BarotropicQGQL.updatevars!(prob)

  energyzeta0 = BarotropicQGQL.energy(prob)
  enstrophyzeta0 = BarotropicQGQL.enstrophy(prob)

  isapprox(energyzeta0, 29.0/9, rtol=1e-13) && isapprox(enstrophyzeta0, 2701.0/162, rtol=1e-13)
end

# -----------------------------------------------------------------------------
# Running the tests


dt, nsteps, stepper  = 1e-2, 20, "ETDRK4"
@test test_bqgql_rossbywave("ETDRK4", dt, nsteps)

dt, nsteps  = 1e-2, 20;
@test test_bqgql_rossbywave("FilteredETDRK4", dt, nsteps)

dt, nsteps  = 1e-2, 20
@test test_bqgql_rossbywave("RK4", dt, nsteps)

dt, nsteps  = 1e-2, 20
@test test_bqgql_rossbywave("FilteredRK4", dt, nsteps)

dt, nsteps  = 1e-3, 200
@test test_bqgql_rossbywave("AB3", dt, nsteps)

dt, nsteps  = 1e-3, 200
@test test_bqgql_rossbywave("FilteredAB3", dt, nsteps)

dt, nsteps  = 1e-4, 2000
@test test_bqgql_rossbywave("ForwardEuler", dt, nsteps)

dt, nsteps  = 1e-4, 2000
@test test_bqgql_rossbywave("FilteredForwardEuler", dt, nsteps)

@test test_bqgql_deterministicforcingbudgets()

@test test_bqgql_stochasticforcingbudgets()

@test test_bqgql_advection(0.0005, "ForwardEuler")

@test test_bqgql_energyenstrophy()
