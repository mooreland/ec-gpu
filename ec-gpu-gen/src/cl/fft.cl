/*
 * FFT algorithm is inspired from: http://www.bealto.com/gpu-fft_group-1.html
 */
KERNEL void FIELD_radix_fft(const GLOBAL FIELD* x, // Source buffer
                      GLOBAL FIELD* y, // Destination buffer
                      const GLOBAL FIELD* pq, // Precalculated twiddle factors
                      GLOBAL FIELD* omegas, // [omega, omega^2, omega^4, ...]
                      LOCAL FIELD* u_arg, // Local buffer to store intermediary values
                      uint n, // Number of elements
                      uint lgp, // Log2 of `p` (Read more in the link above)
                      uint deg, // 1=>radix2, 2=>radix4, 3=>radix8, ...
                      uint max_deg) // Maximum degree supported, according to `pq` and `omegas`
{
// CUDA doesn't support local buffers ("shared memory" in CUDA lingo) as function arguments,
// ignore that argument and use the globally defined extern memory instead.
#ifdef CUDA
  // There can only be a single dynamic shared memory item, hence cast it to the type we need.
  FIELD* u = (FIELD*)cuda_shared;
#else
  LOCAL FIELD* u = u_arg;
#endif

  uint lid = GET_LOCAL_ID();
  uint lsize = GET_LOCAL_SIZE();
  uint index = GET_GROUP_ID();
  uint t = n >> deg;
  uint p = 1 << lgp;
  uint k = index & (p - 1);

  x += index;
  y += ((index - k) << deg) + k;

  uint count = 1 << deg; // 2^deg
  uint counth = count >> 1; // Half of count

  uint counts = count / lsize * lid;
  uint counte = counts + count / lsize;

  // Compute powers of twiddle
  const FIELD twiddle = FIELD_pow_lookup(omegas, (n >> lgp >> deg) * k);
  FIELD tmp = FIELD_pow(twiddle, counts);
  for(uint i = counts; i < counte; i++) {
    u[i] = FIELD_mul(tmp, x[i*t]);
    tmp = FIELD_mul(tmp, twiddle);
  }
  BARRIER_LOCAL();

  const uint pqshift = max_deg - deg;
  for(uint rnd = 0; rnd < deg; rnd++) {
    const uint bit = counth >> rnd;
    for(uint i = counts >> 1; i < counte >> 1; i++) {
      const uint di = i & (bit - 1);
      const uint i0 = (i << 1) - di;
      const uint i1 = i0 + bit;
      tmp = u[i0];
      u[i0] = FIELD_add(u[i0], u[i1]);
      u[i1] = FIELD_sub(tmp, u[i1]);
      if(di != 0) u[i1] = FIELD_mul(pq[di << rnd << pqshift], u[i1]);
    }

    BARRIER_LOCAL();
  }

  for(uint i = counts >> 1; i < counte >> 1; i++) {
    y[i*p] = u[bitreverse(i, deg)];
    y[(i+counth)*p] = u[bitreverse(i + counth, deg)];
  }
}

/// Multiplies all of the elements by `field`
KERNEL void FIELD_mul_by_field(GLOBAL FIELD* elements,
                        uint n,
                        FIELD field) {
  const uint gid = GET_GLOBAL_ID();
  elements[gid] = FIELD_mul(elements[gid], field);
}

KERNEL void FIELD_eval_h_lookups(
  GLOBAL FIELD* value,
  GLOBAL FIELD* table,
  GLOBAL FIELD* permuted_input_coset,
  GLOBAL FIELD* permuted_table_coset,
  GLOBAL FIELD* product_coset,
  GLOBAL FIELD* l0,
  GLOBAL FIELD* l_last,
  GLOBAL FIELD* l_active_row,
  GLOBAL FIELD* y_beta_gamma,
  uint32_t rot_scale,
  uint32_t size
) {
  uint gid = GET_GLOBAL_ID();
  uint idx = gid;

  uint32_t r_next = (idx + rot_scale) & (size - 1);
  uint32_t r_prev = (idx + size - rot_scale) & (size - 1);

  // l_0(X) * (1 - z(X)) = 0
  value[idx] = FIELD_mul(value[idx], y_beta_gamma[0]);
  FIELD tmp = FIELD_sub(FIELD_ONE, product_coset[idx]);
  tmp = FIELD_mul(tmp, l0[idx]);
  value[idx] = FIELD_add(value[idx], tmp);

  // l_last(X) * (z(X)^2 - z(X)) = 0
  value[idx] = FIELD_mul(value[idx], y_beta_gamma[0]);
  tmp = FIELD_sqr(product_coset[idx]);
  tmp = FIELD_sub(tmp, product_coset[idx]);
  tmp = FIELD_mul(tmp, l_last[idx]);
  value[idx] = FIELD_add(value[idx], tmp);

  // (1 - (l_last(X) + l_blind(X))) * (
  //   z(\omega X) (a'(X) + \beta) (s'(X) + \gamma)
  //   - z(X) (\theta^{m-1} a_0(X) + ... + a_{m-1}(X) + \beta)
  //          (\theta^{m-1} s_0(X) + ... + s_{m-1}(X) + \gamma)
  // ) = 0
  value[idx] = FIELD_mul(value[idx], y_beta_gamma[0]);
  tmp = FIELD_add(permuted_input_coset[idx], y_beta_gamma[1]);
  FIELD tmp2 = FIELD_add(permuted_table_coset[idx], y_beta_gamma[2]);
  tmp = FIELD_mul(tmp, tmp2);
  tmp = FIELD_mul(tmp, product_coset[r_next]);
  tmp2 = FIELD_mul(product_coset[idx], table[idx]);
  tmp = FIELD_sub(tmp, tmp2);
  tmp = FIELD_mul(tmp, l_active_row[idx]);
  value[idx] = FIELD_add(value[idx], tmp);

  // l_0(X) * (a'(X) - s'(X)) = 0
  value[idx] = FIELD_mul(value[idx], y_beta_gamma[0]);
  tmp2 = FIELD_sub(permuted_input_coset[idx], permuted_table_coset[idx]);
  tmp = FIELD_mul(tmp2, l0[idx]);
  value[idx] = FIELD_add(value[idx], tmp);

  // (1 - (l_last + l_blind)) * (a′(X) − s′(X))⋅(a′(X) − a′(\omega^{-1} X)) = 0
  value[idx] = FIELD_mul(value[idx], y_beta_gamma[0]);
  tmp = FIELD_sub(permuted_input_coset[idx], permuted_input_coset[r_prev]);
  tmp = FIELD_mul(tmp, tmp2);
  tmp = FIELD_mul(tmp, l_active_row[idx]);
  value[idx] = FIELD_add(value[idx], tmp);
}
