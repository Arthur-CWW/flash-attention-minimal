#include <torch/types.h>
#include <cuda.h>
#include <cuda_runtime.h>

__global__ void forward_kernel(const float* Q, const float* K, const float* V, const int N, const int d,
							   const int Tc, const int Tr, const int Bc, const int Br, const float softmax_scale,
							   float* l, float* m, float* O) {
	int tx = threadIdx.x;
	int bx = blockIdx.x;
	int by = blockIdx.y;  // batch and head index

	// Offset into Q,K,V,O,l,m - different for each batch and head
	int qkv_offset = (bx * gridDim.y * N * d) + (by * N * d);  // gridDim.y = nh
	int lm_offset = (bx * gridDim.y * N) + (by * N);		   // offset for l and m

	// Define SRAM for Q,K,V,S
	extern __shared__ float sram[];
	int tile_size = Bc * d;	 // size of Qi, Kj, Vj
	float* Qi = sram;
	float* Kj = &sram[tile_size];
	float* Vj = &sram[tile_size * 2];
	float* S = &sram[tile_size * 3];

	for (int j = 0; j < Tc; j++) {
		// Load Kj, Vj to SRAM
		for (int x = 0; x < d; x++) {
			Kj[(tx * d) + x] = K[qkv_offset + (tile_size * j) + (tx * d) + x];
			Vj[(tx * d) + x] = V[qkv_offset + (tile_size * j) + (tx * d) + x];
		}
		__syncthreads();  // such that the inner loop can use the correct Kj, Vj
		// TODO fill this in

		__syncthreads();  // otherwise, thread can use the wrong Kj, Vj in inner loop
	}
}

torch::Tensor forward(torch::Tensor Q, torch::Tensor K, torch::Tensor V) {
	// TODO: determine Bc, Br dynamically
	const int Bc = 32;
	const int Br = 32;

	const int B = Q.size(0);
	const int nh = Q.size(1);
	const int N = Q.size(2);
	const int d = Q.size(3);

	const int Tc = ceil((float)N / Bc);
	const int Tr = ceil((float)N / Br);
	const float softmax_scale = 1.0 / sqrt(d);

	// Initialize O, l, m to HBM
	auto O = torch::zeros_like(Q);
	auto l = torch::zeros({B, nh, N});
	auto m = torch::full({B, nh, N}, -INFINITY);
	torch::Device device(torch::kCUDA);
	l = l.to(device);
	m = m.to(device);

	// Calculate SRAM size needed per block
	const int sram_size = (3 * Bc * d * sizeof(float)) + (Bc * Br * sizeof(float));
	int max_sram_size;
	cudaDeviceGetAttribute(&max_sram_size, cudaDevAttrMaxSharedMemoryPerBlock, 0);
	printf("Max shared memory: %d, requested shared memory: %d \\n", max_sram_size, sram_size);

	dim3 grid_dim(B, nh);  // batch_size x num_heads
	dim3 block_dim(Bc);	   // Bc threads per block

	forward_kernel<<<grid_dim, block_dim, sram_size>>>(
		Q.data_ptr<float>(), K.data_ptr<float>(), V.data_ptr<float>(),
		N, d, Tc, Tr, Bc, Br, softmax_scale,
		l.data_ptr<float>(), m.data_ptr<float>(), O.data_ptr<float>());
	return O;
}