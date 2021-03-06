#include <algorithm>
#include <math.h>
#include <float.h>
#include <utility>
#include <stdio.h>
#include <cstring>
#include <vector>
#include <unistd.h>
#include "cudaRenderer.h"
#include "image.h"
#include "util.h"

#include <cuda.h>
#include <cuda_runtime.h>
#include <driver_functions.h>

#define CELL_DIM 1
#define TIME_STEP 1
#define BLOCKSIDE 16
#define BLOCKSIZE BLOCKSIDE*BLOCKSIDE
///////////////////////////CUDA CODE BELOW////////////////////////////////
struct GlobalConstants {
    int cells_per_side;
    int width;
    int height;

    float* VX;
    float* VY;
    float* pressures;
    float* pressuresCopy;
    float* VXCopy;
    float* VYCopy;
    float* divergence;
    float* vorticity;
    float* color;
    float* colorCopy;
    float* imageData;

    int* mpls;
};

__constant__ GlobalConstants cuParams;

// kernelClearImage
__global__ void kernelClearImage(float r, float g, float b, float a) {
    int imageX = blockIdx.x * blockDim.x + threadIdx.x;
    int imageY = blockIdx.y * blockDim.y + threadIdx.y;

    int width = cuParams.width;
    int height = cuParams.height;

    if (imageX >= width || imageY >= height) return;

    int offset = 4 * (imageY * width + imageX);
    float4 value = make_float4(r,g,b,a);
    
    // Write to global memory.
    *(float4*)(&cuParams.imageData[offset]) = value;

}


__device__ __inline__ int
isBoundary(int i, int j) {
    int cells_per_side = cuParams.cells_per_side;
    if (j == 0) return 1; // left 
    if (i == 0) return 2; // top
    if (j == cells_per_side) return 3; // right
    if (i == cells_per_side) return 4; // bottom
    return 0;
}

__device__ __inline__ int
isInBox(int row, int col, int blockDimX, int blockDimY, int blockIdxX, int blockIdxY) {
    int minRow = blockIdxY * blockDimY;
    int maxRow = minRow + blockDimY;
    int minCol = blockIdxX * blockDimX;
    int maxCol = minCol + blockDimX;
    if (row >= minRow && row < maxRow && col >= minCol && col < maxCol) return 1;
    return 0;
}

// a is prev mouse point, b is cur mouse point, p is point to consider,
// fp is fraction projection to be populated as output
__device__ __inline__ double 
distanceToSegment(double ax, double ay, double bx, double by, 
        double px, double py, double* fp) {
    double dx = px - ax; //vec2 d = p - a;
    double dy = py - ay;
    double xx = bx - ax; //vec2 x = b - a;
    double xy = by - ay;
    *fp = 0.0; // fractional projection, 0 - 1 in the length of b-a
    double lx = sqrt(xx*xx + xy*xy); //length(x)
    double ld = sqrt(dx*dx + dy*dy); //length(d)
    if (lx <= 0.0001) return ld;
    double projection = dx*(xx/lx) + dy*(xy/lx); //dot(d, x/lx)
    *fp = projection / lx;
    if (projection < 0.0) return ld;
    else if (projection > lx) return sqrt((px-bx) * (px-bx) +
            (py-by) * (py-by)); //length(p - b)
    return sqrt(abs(dx*dx + dy*dy - projection * projection));
}

__device__ __inline__ double 
distanceToNearestMouseSegment(double px, double py, double *fp,
        double* vx, double *vy) {
    double minLen = DBL_MAX;
    double fpResult = 0.0;
    double vxResult = 0.0;
    double vyResult = 0.0;
    for (int i = 0; i < 400 - 2; i += 2) {

        int grid_col1 = cuParams.mpls[i];
        int grid_row1 = cuParams.mpls[i + 1];
        int grid_col2 = cuParams.mpls[i + 2];
        int grid_row2 = cuParams.mpls[i + 3];
        if (grid_col2 == 0 & grid_row2 == 0) break;
        double len = distanceToSegment(grid_col1, grid_row1, grid_col2, grid_row2, px, py, fp);
        if (len < minLen) {
            minLen = len;
            fpResult = *fp;
            vxResult = grid_col2 - grid_col1;
            vyResult = grid_row2 - grid_row1;
        }        

    }
    *fp = fpResult;
    *vx = vxResult;
    *vy = vyResult;
    return minLen;
}

//kernelFadeVelocities
__global__ void kernelFadeVelocities() {
    int grid_col = blockIdx.x * blockDim.x + threadIdx.x;
    int grid_row = blockIdx.y * blockDim.y + threadIdx.y; 
    int width = cuParams.width;
    int height = cuParams.height;

    if (grid_col >= width || grid_row >= height) return;
    if (grid_row * width + grid_col >= width * height) return; 
    
    cuParams.VX[grid_row * width + grid_col] *= 0.999;
    cuParams.VY[grid_row * width + grid_col] *= 0.999;
}

//kernelSetNewVelocities
__global__ void kernelSetNewVelocities() {
    int grid_col = blockIdx.x * blockDim.x + threadIdx.x;
    int grid_row = blockIdx.y * blockDim.y + threadIdx.y; 
    int width = cuParams.width;
    int height = cuParams.height;

    if (grid_col >= width || grid_row >= height) return;
    if (grid_row * width + grid_col >= width * height) return; 
    
    int imageX = grid_col;
    int imageY = grid_row;
    int offset = 4 * (imageY * width + imageX);
    float4 value = make_float4(1.f,0.f,1.f,1.f);

    // Write to global memory.
    *(float4*)(&cuParams.imageData[offset]) = value;
   
    cuParams.VX[grid_row * width + grid_col] *= 0.999;
    cuParams.VY[grid_row * width + grid_col] *= 0.999;
    double projection;
    double vx;
    double vy;
    double l = distanceToNearestMouseSegment(grid_col, grid_row, 
            &projection, &vx, &vy);
    //printf("velocity %f,%f\n", mouseSegmentVelocity.first, mouseSegmentVelocity.second);
    double taperFactor = 0.6;
    double projectedFraction = 1.0 - fminf(1.0, fmaxf(projection, 0.0)) * taperFactor;
    double R = 10;
    double m = exp(-l/R); //drag coefficient
    m *= projectedFraction * projectedFraction;
    double targetVelocityX = vx * 1 * 1.4; 
    double targetVelocityY = vy * 1 * 1.4; 

    cuParams.VX[grid_row * width + grid_col] += 
        (targetVelocityX - cuParams.VX[grid_row * width + grid_col]) * m;
    cuParams.VY[grid_row * width + grid_col] += 
        (targetVelocityY - cuParams.VY[grid_row * width + grid_col]) * m;

}

//kernelCopyVelocities
__global__ void kernelCopyVelocities() {
    int col = blockIdx.x * blockDim.x + threadIdx.x;
    int row = blockIdx.y * blockDim.y + threadIdx.y; 
    int width = cuParams.width;
    int height = cuParams.height;

    if (col >= width || row >= height) return;
    if (row * width + col >= width * height) return; 

    cuParams.VXCopy[row * width + col] = cuParams.VX[row * width + col];
    cuParams.VYCopy[row * width + col] = cuParams.VY[row * width + col];
}

//kernelAdvectVelocityForward
__global__ void kernelAdvectVelocityForward() {
    int cells_per_side = cuParams.cells_per_side;
    int rowInBox = threadIdx.y;
    int colInBox = threadIdx.x;
    int boxWidth = blockDim.x;
    int colOnScreen = blockIdx.x * blockDim.x + threadIdx.x;
    int rowOnScreen = blockIdx.y * blockDim.y + threadIdx.y; 
    int width = cuParams.width;
    int height = cuParams.height;

    if (colOnScreen >= width || rowOnScreen >= height) return;
    if (rowOnScreen * width + colOnScreen >= width * height) return;

   __shared__ float sharedVX[BLOCKSIZE]; 
   __shared__ float sharedVY[BLOCKSIZE]; 
    sharedVX[rowInBox * boxWidth + colInBox] =
        cuParams.VXCopy[rowOnScreen * width + colOnScreen];
    sharedVY[rowInBox * boxWidth + colInBox] =
        cuParams.VYCopy[rowOnScreen * width + colOnScreen];
    __syncthreads();

   int nextRowOnScreen = round(rowOnScreen + TIME_STEP * cuParams.VYCopy[rowOnScreen * width + colOnScreen]);
   int nextColOnScreen = round(colOnScreen + TIME_STEP * cuParams.VXCopy[rowOnScreen * width + colOnScreen]);
   if (nextColOnScreen < cells_per_side && nextRowOnScreen < cells_per_side 
           && nextColOnScreen >= 0 && nextRowOnScreen >= 0) {
       
       if (isInBox(nextRowOnScreen, nextColOnScreen, blockDim.x, blockDim.y, blockIdx.x, blockIdx.y)) {
            int r = nextRowOnScreen % blockDim.y;
            int c = nextColOnScreen % blockDim.x;
            cuParams.VX[nextRowOnScreen * width + nextColOnScreen] = sharedVX[r * boxWidth + c];
            cuParams.VY[nextRowOnScreen * width + nextColOnScreen] = sharedVY[r * boxWidth + c];
       } else {
            cuParams.VX[nextRowOnScreen * width + nextColOnScreen] = cuParams.VXCopy[rowOnScreen * width + colOnScreen];
            cuParams.VY[nextRowOnScreen * width + nextColOnScreen] = cuParams.VYCopy[rowOnScreen * width + colOnScreen];
       }
   }
}

//kernelAdvectVelocityBackward
__global__ void kernelAdvectVelocityBackward() {
    int cells_per_side = cuParams.cells_per_side;
    int rowInBox = threadIdx.y;
    int colInBox = threadIdx.x;
    int boxWidth = blockDim.x;
    int colOnScreen = blockIdx.x * blockDim.x + threadIdx.x;
    int rowOnScreen = blockIdx.y * blockDim.y + threadIdx.y; 
    int width = cuParams.width;
    int height = cuParams.height;

    if (colOnScreen >= width || rowOnScreen >= height) return;
    if (rowOnScreen * width + colOnScreen >= width * height) return; 

    __shared__ float sharedVX[BLOCKSIZE]; 
   __shared__ float sharedVY[BLOCKSIZE]; 
    sharedVX[rowInBox * boxWidth + colInBox] =
        cuParams.VXCopy[rowOnScreen * width + colOnScreen];
    sharedVY[rowInBox * boxWidth + colInBox] =
        cuParams.VYCopy[rowOnScreen * width + colOnScreen];
    __syncthreads();

   int prevRowOnScreen = round(rowOnScreen - TIME_STEP * cuParams.VYCopy[rowOnScreen * width + colOnScreen]);
   int prevColOnScreen = round(colOnScreen - TIME_STEP * cuParams.VXCopy[rowOnScreen * width + colOnScreen]);

   if (prevColOnScreen < cells_per_side && prevColOnScreen < cells_per_side 
           && prevColOnScreen >= 0 && prevRowOnScreen >= 0) {
       if (isInBox(prevRowOnScreen, prevColOnScreen, blockDim.x, blockDim.y, blockIdx.x, blockIdx.y)) {
            int r = prevRowOnScreen % blockDim.y;
            int c = prevColOnScreen % blockDim.x;
            cuParams.VX[rowOnScreen * width + colOnScreen] = sharedVX[r * boxWidth + c];
            cuParams.VY[rowOnScreen * width + colOnScreen] = sharedVY[r * boxWidth + c];
       } else {
            cuParams.VX[rowOnScreen * width + colOnScreen] = cuParams.VXCopy[prevRowOnScreen * width + prevColOnScreen];
            cuParams.VY[rowOnScreen * width + colOnScreen] = cuParams.VYCopy[prevRowOnScreen * width + prevColOnScreen];
       }
   } 
   if (prevColOnScreen == colOnScreen && prevRowOnScreen == rowOnScreen) {
        // you don't move so just disappear
        cuParams.VX[rowOnScreen * width + colOnScreen] = 0;
        cuParams.VY[rowOnScreen * width + colOnScreen] = 0;
   }
}

//kernelApplyVorticity
__global__ void kernelApplyVorticity(){
    int cells_per_side = cuParams.cells_per_side;
    int rowInBox = threadIdx.y;
    int colInBox = threadIdx.x;
    int boxWidth = blockDim.x;
    int colOnScreen = blockIdx.x * blockDim.x + threadIdx.x;
    int rowOnScreen = blockIdx.y * blockDim.y + threadIdx.y; 
    int width = cuParams.width;
    int height = cuParams.height;

    // SIENNA - is it bad if some threads return but then later we 
    // call __syncthreads() ??
    if (rowOnScreen * width + colOnScreen >= width * height) return; 
    
    //int blockSize = blockDim.x * blockDim.y;
    __shared__ float sharedVX[BLOCKSIZE];
    __shared__ float sharedVY[BLOCKSIZE];
    sharedVX[rowInBox * boxWidth + colInBox] = 
        cuParams.VX[rowOnScreen * width + colOnScreen];
    sharedVY[rowInBox * boxWidth + colInBox] = 
        cuParams.VY[rowOnScreen * width + colOnScreen];
   
    __syncthreads(); //now everything in the box should be loaded into shared mem.

    //if (isBoundary(row,col)) return;
    if (!isBoundary(rowOnScreen,colOnScreen)) {
        float L = 0.0;
        float R = 0.0;
        float B = 0.0;
        float T = 0.0;
        int r = 0;
        int c = 0;
        if (rowOnScreen > 0) {
            if (isInBox(rowOnScreen-1, colOnScreen, blockDim.x, blockDim.y, blockIdx.x, blockIdx.y)) {
                r = (rowOnScreen - 1) % blockDim.y;
                c = colOnScreen % blockDim.x;
                T = sharedVX[r*boxWidth + c];
                //if (blockIdx.x == 3 && blockIdx.y == 3) printf("T from shared\n");
            } else {
                T = cuParams.VX[(rowOnScreen-1) * width + colOnScreen];
                //if (blockIdx.x == 3 && blockIdx.y == 3) printf("%d, %d\n", rowInBox, colInBox);
            }
        }
        if (rowOnScreen < cells_per_side) {
            if (isInBox(rowOnScreen+1, colOnScreen, blockDim.x, blockDim.y, blockIdx.x, blockIdx.y)) {
                r = (rowOnScreen + 1) % blockDim.y;
                c = colOnScreen % blockDim.x;
                B = sharedVX[r*boxWidth + c];
                //if (blockIdx.x == 0 && blockIdx.y == 0) printf("B from shared\n");
            } else {
                B = cuParams.VX[(rowOnScreen+1) * width + colOnScreen];
            }
        }
        if (colOnScreen < cells_per_side) {
            if (isInBox(rowOnScreen, colOnScreen+1, blockDim.x, blockDim.y, blockIdx.x, blockIdx.y)) {
                r = rowOnScreen % blockDim.y;
                c = (colOnScreen + 1) % blockDim.x;
                R = sharedVY[r*boxWidth + c];
                //if (blockIdx.x == 0 && blockIdx.y == 0) printf("R from shared\n");
            } else {
                R = cuParams.VY[rowOnScreen * width + (colOnScreen+1)];
            }
        }
        if (colOnScreen > 0) {
            if (isInBox(rowOnScreen, colOnScreen-1, blockDim.x, blockDim.y, blockIdx.x, blockIdx.y)) {
                r = rowOnScreen % blockDim.y;
                c = (colOnScreen - 1) % blockDim.x;
                L = sharedVY[r*boxWidth + c];
                //if (blockIdx.x == 0 && blockIdx.y == 0) printf("L from shared\n");
            } else {
                L = cuParams.VY[rowOnScreen * width + (colOnScreen-1)];
            }
        }
        cuParams.vorticity[rowOnScreen * width + colOnScreen] = 0.5 * ((R - L) - (T - B));
    }
}

//kernelApplyVorticityForce
__global__ void kernelApplyVorticityForce(){
    int cells_per_side = cuParams.cells_per_side;
    int rowInBox = threadIdx.y;
    int colInBox = threadIdx.x;
    int boxWidth = blockDim.x;
    int colOnScreen = blockIdx.x * blockDim.x + threadIdx.x;
    int rowOnScreen = blockIdx.y * blockDim.y + threadIdx.y; 
    int width = cuParams.width;
    int height = cuParams.height;

    if (rowOnScreen * width + colOnScreen >= width * height) return; 

    __shared__ float sharedVort[BLOCKSIZE];
   sharedVort[rowInBox * boxWidth + colInBox] =
       cuParams.vorticity[rowOnScreen * width + colOnScreen];
   __syncthreads();

            
    if (!isBoundary(rowOnScreen,colOnScreen)) {
        float vortConfinementFloat = 0.035f;
        float vortL = 0.0;
        float vortR = 0.0;
        float vortB = 0.0;
        float vortT = 0.0;
        float vortC = 0.0;
        int r = 0;
        int c= 0;

        if (rowOnScreen > 0) {
           if (isInBox(rowOnScreen-1, colOnScreen, blockDim.x, blockDim.y, blockIdx.x, blockIdx.y)) {
                r = (rowOnScreen - 1) % blockDim.y;
                c = colOnScreen % blockDim.x;
                vortT = sharedVort[r * boxWidth + c];
           } else {
               vortT = cuParams.vorticity[(rowOnScreen-1) * width + colOnScreen];
           }
        }
        if (rowOnScreen < cells_per_side) {
            if (isInBox(rowOnScreen+1, colOnScreen, blockDim.x, blockDim.y, blockIdx.x, blockIdx.y)) {
                r = (rowOnScreen + 1) % blockDim.y; 
                c = colOnScreen % blockDim.x;
                vortB = sharedVort[r * boxWidth + c];
            } else {
                vortB = cuParams.vorticity[(rowOnScreen+1) * width + colOnScreen];
            }
        }
        if (colOnScreen < cells_per_side) {
            if (isInBox(rowOnScreen, colOnScreen+1, blockDim.x, blockDim.y, blockIdx.x, blockIdx.y)) {
                r = rowOnScreen % blockDim.y;
                c = (colOnScreen+1) % blockDim.x;
                vortR = sharedVort[r * boxWidth + c];
            } else {
                vortR = cuParams.vorticity[rowOnScreen * width + (colOnScreen+1)];
            }
        }
        if (rowOnScreen > 0) {
            if (isInBox(rowOnScreen, colOnScreen-1, blockDim.x, blockDim.y, blockIdx.x, blockIdx.y)) {
                r = rowOnScreen % blockDim.y;
                c = (colOnScreen-1) % blockDim.x;
                vortL = sharedVort[r * boxWidth + c];
            } else {
                vortL = cuParams.vorticity[rowOnScreen * width + (colOnScreen-1)];
            }
        }
        vortC = cuParams.vorticity[rowOnScreen * width + colOnScreen];
        
        float forceX = 0.5 * (fabsf(vortT) - fabsf(vortB));
        float forceY = 0.5 * (fabsf(vortR) - fabsf(vortL));
        float EPSILON = powf(2,-12);
        float magSqr = fmaxf(EPSILON, forceX * forceX + forceY * forceY);
        forceX = forceX * (1/sqrtf(magSqr));
        forceY = forceY * (1/sqrtf(magSqr));
        forceX *= vortConfinementFloat * vortC * 1;
        forceY *= vortConfinementFloat * vortC * -1;
        cuParams.VX[rowOnScreen * width + colOnScreen] += forceX;
        cuParams.VY[rowOnScreen * width + colOnScreen] += forceY;
    }
}

//kernelApplyDivergence
__global__ void kernelApplyDivergence() {
    int cells_per_side = cuParams.cells_per_side;
    int rowInBox = threadIdx.y;
    int colInBox = threadIdx.x;
    int boxWidth = blockDim.x;
    int colOnScreen = blockIdx.x * blockDim.x + threadIdx.x;
    int rowOnScreen = blockIdx.y * blockDim.y + threadIdx.y; 
    int width = cuParams.width;
    int height = cuParams.height;

    if (rowOnScreen * width + colOnScreen >= width * height) return; 

    __shared__ float sharedVX[BLOCKSIZE];
    __shared__ float sharedVY[BLOCKSIZE];
    sharedVX[rowInBox * boxWidth + colInBox] = 
        cuParams.VX[rowOnScreen * width + colOnScreen];
    sharedVY[rowInBox * boxWidth + colInBox] = 
        cuParams.VY[rowOnScreen * width + colOnScreen];
     __syncthreads();

    if (!isBoundary(rowOnScreen,colOnScreen)) {
        float L = 0.0;
        float R = 0.0;
        float B = 0.0;
        float T = 0.0;
        int r = 0;
        int c = 0;

        if (rowOnScreen > 0) {
            if (isInBox(rowOnScreen-1, colOnScreen, blockDim.x, blockDim.y, blockIdx.x, blockIdx.y)) {
                r = (rowOnScreen - 1) % blockDim.y;
                c = colOnScreen % blockDim.x;
                T = sharedVY[r * boxWidth + c];
            } else {
                T = cuParams.VY[(rowOnScreen-1) * width + colOnScreen];
            }
        }
        if (rowOnScreen < cells_per_side) {
            if (isInBox(rowOnScreen+1, colOnScreen, blockDim.x, blockDim.y, blockIdx.x, blockIdx.y)) {
                r = (rowOnScreen + 1) % blockDim.y;
                c = colOnScreen % blockDim.x;
                B = sharedVY[r * boxWidth + c];
            } else {
                B = cuParams.VY[(rowOnScreen+1) * width + colOnScreen];
            }
        }
        if (colOnScreen < cells_per_side) {
            if (isInBox(rowOnScreen, colOnScreen+1, blockDim.x, blockDim.y, blockIdx.x, blockIdx.y)) {
                r = rowOnScreen % blockDim.y;
                c = (colOnScreen+1) % blockDim.x;
                R = sharedVX[r * boxWidth + c];
            } else {
                R = cuParams.VX[rowOnScreen * width + (colOnScreen+1)];
            }
        }
        if (colOnScreen > 0) {
            if (isInBox(rowOnScreen, colOnScreen-1, blockDim.x, blockDim.y, blockIdx.x, blockIdx.y)) {
                r = rowOnScreen % blockDim.y;
                c = (colOnScreen-1) % blockDim.x;
                L = sharedVX[r * boxWidth + c];
            } else {
                L = cuParams.VX[rowOnScreen * width + (colOnScreen-1)];
            }
        }
        cuParams.divergence[rowOnScreen * width + colOnScreen] = 0.5*((R-L) + (T-B));
    }
}

//kernelCopyPressures
__global__ void kernelCopyPressures() {
    int col = blockIdx.x * blockDim.x + threadIdx.x;
    int row = blockIdx.y * blockDim.y + threadIdx.y; 
    int width = cuParams.width;
    int height = cuParams.height;

    if (col >= width || row >= height) return;
    if (row * width + col >= width * height) return; 

    cuParams.pressuresCopy[row * width + col] = cuParams.pressures[row * width + col];
    cuParams.pressuresCopy[row * width + col] = cuParams.pressures[row * width + col];
}

//kernelPressureSolve
__global__ void kernelPressureSolve(){
    int cells_per_side = cuParams.cells_per_side;
    int rowInBox = threadIdx.y;
    int colInBox = threadIdx.x;
    int boxWidth = blockDim.x;
    int colOnScreen = blockIdx.x * blockDim.x + threadIdx.x;
    int rowOnScreen = blockIdx.y * blockDim.y + threadIdx.y; 
    int width = cuParams.width;
    int height = cuParams.height;

    if (rowOnScreen * width + colOnScreen >= width * height) return; 

    __shared__ float sharedPressuresCopy[BLOCKSIZE];
    sharedPressuresCopy[rowInBox * boxWidth + colInBox] =
       cuParams.pressuresCopy[rowOnScreen * width + colOnScreen];
    __syncthreads();
    
    if (!isBoundary(rowOnScreen,colOnScreen)) {
        float L = 0.0;
        float R = 0.0;
        float B = 0.0;
        float T = 0.0;
        int r = 0;
        int c = 0;

        if (rowOnScreen > 0) {
            if (isInBox(rowOnScreen-1, colOnScreen, blockDim.x, blockDim.y, blockIdx.x, blockIdx.y)) {
                r = (rowOnScreen - 1) % blockDim.y;
                c = colOnScreen % blockDim.x;
                T = sharedPressuresCopy[r * boxWidth + c];
            } else {
                T = cuParams.pressuresCopy[(rowOnScreen-1) * width + colOnScreen];
            }
        }
        if (rowOnScreen < cells_per_side) {
            if (isInBox(rowOnScreen+1, colOnScreen, blockDim.x, blockDim.y, blockIdx.x, blockIdx.y)) {
                r = (rowOnScreen + 1) % blockDim.y;
                c = colOnScreen % blockDim.x;
                B = sharedPressuresCopy[r * boxWidth + c];
            } else {
                B = cuParams.pressuresCopy[(rowOnScreen+1) * width + colOnScreen];
            }
        }
        if (colOnScreen < cells_per_side) {
            if (isInBox(rowOnScreen, colOnScreen+1, blockDim.x, blockDim.y, blockIdx.x, blockIdx.y)) {
                r = rowOnScreen % blockDim.y;
                c = (colOnScreen+1) % blockDim.x;
                R = sharedPressuresCopy[r * boxWidth + c];
            } else { 
                R = cuParams.pressuresCopy[rowOnScreen * width + (colOnScreen+1)];
            }
        }
        if (colOnScreen > 0) {
            if (isInBox(rowOnScreen, colOnScreen-1, blockDim.x, blockDim.y, blockIdx.x, blockIdx.y)) {
                r = rowOnScreen % blockDim.y;
                c = (colOnScreen-1) % blockDim.x;
                L = sharedPressuresCopy[r * boxWidth + c];
            } else {
                L = cuParams.pressuresCopy[rowOnScreen * width + (colOnScreen-1)];
            }
        }
        cuParams.pressures[rowOnScreen * width + colOnScreen] = 
            (L + R + B + T + -1 * cuParams.divergence[rowOnScreen * width + colOnScreen]) * .25;
    }
}

//kernelPressureGradient
__global__ void kernelPressureGradient(){
    int cells_per_side = cuParams.cells_per_side;
    int rowInBox = threadIdx.y;
    int colInBox = threadIdx.x;
    int boxWidth = blockDim.x;
    int colOnScreen = blockIdx.x * blockDim.x + threadIdx.x;
    int rowOnScreen = blockIdx.y * blockDim.y + threadIdx.y; 
    int width = cuParams.width;
    int height = cuParams.height;

    if (rowOnScreen * width + colOnScreen >= width * height) return; 

    __shared__ float sharedPressures[BLOCKSIZE];
    sharedPressures[rowInBox * boxWidth + colInBox] = 
        cuParams.pressures[rowOnScreen * width + colOnScreen];
    __syncthreads(); //now everything in the box should be loaded into shared mem.
    
    if (!isBoundary(rowOnScreen,colOnScreen)) {

        float L = 0.0;
        float R = 0.0;
        float B = 0.0;
        float T = 0.0;
        int r = 0;
        int c = 0;

        if (rowOnScreen > 0) {
            if (isInBox(rowOnScreen-1, colOnScreen, blockDim.x, blockDim.y, blockIdx.x, blockIdx.y)) {
                r = (rowOnScreen - 1) % blockDim.y;
                c = colOnScreen % blockDim.x;
                T = sharedPressures[r * boxWidth + c];
            } else { 
                T = cuParams.pressures[(rowOnScreen-1) * width + colOnScreen];
            }
        }
        if (rowOnScreen < cells_per_side) {
            if (isInBox(rowOnScreen+1, colOnScreen, blockDim.x, blockDim.y, blockIdx.x, blockIdx.y)) {
                r = (rowOnScreen + 1) % blockDim.y;
                c = colOnScreen % blockDim.x;
                B = sharedPressures[r * boxWidth + c];
            } else {
                B = cuParams.pressures[(rowOnScreen+1) * width + colOnScreen];
            }
        }
        if (colOnScreen < cells_per_side) {
            if (isInBox(rowOnScreen, colOnScreen+1, blockDim.x, blockDim.y, blockIdx.x, blockIdx.y)) {
                r = rowOnScreen % blockDim.y;
                c = (colOnScreen+1) % blockDim.x;
                R = sharedPressures[r * boxWidth + c];
            } else {
                R = cuParams.pressures[rowOnScreen * width + (colOnScreen+1)];
            }
        }
        if (colOnScreen > 0) {
            if (isInBox(rowOnScreen, colOnScreen-1, blockDim.x, blockDim.y, blockIdx.x, blockIdx.y)) {
                r = rowOnScreen % blockDim.y;
                c = (colOnScreen-1) % blockDim.x;
                L = sharedPressures[r * boxWidth + c];
            } else {
                L = cuParams.pressures[rowOnScreen * width + (colOnScreen-1)];
            }
        }
        cuParams.VX[rowOnScreen * width + colOnScreen] = cuParams.VX[rowOnScreen * width + colOnScreen] - 0.5*(R - L);
        cuParams.VY[rowOnScreen * width + colOnScreen] = cuParams.VY[rowOnScreen * width + colOnScreen] - 0.5*(T - B);
    }
}

//kernelCopyColor
__global__ void kernelCopyColor() {
    int col = blockIdx.x * blockDim.x + threadIdx.x;
    int row = blockIdx.y * blockDim.y + threadIdx.y; 
    int width = cuParams.width;
    int height = cuParams.height;

    if (col >= width || row >= height) return;
    if (row * width + col >= width * height) return; 

    int index = 4 * (row * width + col);
    cuParams.colorCopy[index] = cuParams.color[index];
    cuParams.colorCopy[index + 1] = cuParams.color[index + 1];
    cuParams.colorCopy[index + 2] = cuParams.color[index + 2];
    cuParams.colorCopy[index + 3] = cuParams.color[index + 3];
}

//kernelAdvectColorForward
__global__ void kernelAdvectColorForward() {
    int cells_per_side = cuParams.cells_per_side;
    int rowInBox = threadIdx.y;
    int colInBox = threadIdx.x;
    int boxWidth = blockDim.x;
    int colOnScreen = blockIdx.x * blockDim.x + threadIdx.x;
    int rowOnScreen = blockIdx.y * blockDim.y + threadIdx.y; 
    int width = cuParams.width;
    int height = cuParams.height;

    if (colOnScreen >= width || rowOnScreen >= height) return;
    if (rowOnScreen * width + colOnScreen >= width * height) return; 

     __shared__ float sharedColorCopy[4 * BLOCKSIZE];
     sharedColorCopy[(rowInBox * boxWidth + colInBox) * 4 + 0] = cuParams.colorCopy[(rowOnScreen * width + colOnScreen) * 4 + 0];
     sharedColorCopy[(rowInBox * boxWidth + colInBox) * 4 + 1] = cuParams.colorCopy[(rowOnScreen * width + colOnScreen) * 4 + 1];
     sharedColorCopy[(rowInBox * boxWidth + colInBox) * 4 + 2] = cuParams.colorCopy[(rowOnScreen * width + colOnScreen) * 4 + 2];
     sharedColorCopy[(rowInBox * boxWidth + colInBox) * 4 + 3] = cuParams.colorCopy[(rowOnScreen * width + colOnScreen) * 4 + 3];
    __syncthreads();

    int nextRowOnScreen = round(rowOnScreen + TIME_STEP * cuParams.VY[rowOnScreen * width + colOnScreen]);
    int nextColOnScreen = round(colOnScreen + TIME_STEP * cuParams.VX[rowOnScreen * width + colOnScreen]);

   if (nextColOnScreen < cells_per_side && nextRowOnScreen < cells_per_side 
           && nextColOnScreen >= 0 && nextRowOnScreen >= 0) {
        if (isInBox(nextRowOnScreen, nextColOnScreen, blockDim.x, blockDim.y, blockIdx.x, blockIdx.y)) {
            int r = nextRowOnScreen % blockDim.y;
            int c = nextColOnScreen % blockDim.x;
            cuParams.color[(nextRowOnScreen * width + nextColOnScreen) * 4 + 0] = sharedColorCopy[(r * boxWidth + c) * 4 + 0];
            cuParams.color[(nextRowOnScreen * width + nextColOnScreen) * 4 + 1] = sharedColorCopy[(r * boxWidth + c) * 4 + 1];
            cuParams.color[(nextRowOnScreen * width + nextColOnScreen) * 4 + 2] = sharedColorCopy[(r * boxWidth + c) * 4 + 2];
            cuParams.color[(nextRowOnScreen * width + nextColOnScreen) * 4 + 3] = sharedColorCopy[(r * boxWidth + c) * 4 + 3];
        } else {
            cuParams.color[(nextRowOnScreen * width + nextColOnScreen) * 4 + 0] = 
                cuParams.colorCopy[(rowOnScreen * width + colOnScreen) * 4 + 0];
            cuParams.color[(nextRowOnScreen * width + nextColOnScreen) * 4 + 1] = 
                cuParams.colorCopy[(rowOnScreen * width + colOnScreen) * 4 + 1];
            cuParams.color[(nextRowOnScreen * width + nextColOnScreen) * 4 + 2] = 
                cuParams.colorCopy[(rowOnScreen * width + colOnScreen) * 4 + 2];
            cuParams.color[(nextRowOnScreen * width + nextColOnScreen) * 4 + 3] = 
                cuParams.colorCopy[(rowOnScreen * width + colOnScreen) * 4 + 3];
        }

   } 
}

//kernelAdvectColorBackward
__global__ void kernelAdvectColorBackward() {
    int cells_per_side = cuParams.cells_per_side;
    int rowInBox = threadIdx.y;
    int colInBox = threadIdx.x;
    int boxWidth = blockDim.x;
    int colOnScreen = blockIdx.x * blockDim.x + threadIdx.x;
    int rowOnScreen = blockIdx.y * blockDim.y + threadIdx.y; 
    int width = cuParams.width;
    int height = cuParams.height;

    if (colOnScreen >= width || rowOnScreen >= height) return;
    if (rowOnScreen * width + colOnScreen >= width * height) return; 

    __shared__ float sharedColorCopy[4 * BLOCKSIZE];
     sharedColorCopy[(rowInBox * boxWidth + colInBox) * 4 + 0] = cuParams.colorCopy[(rowOnScreen * width + colOnScreen) * 4 + 0];
     sharedColorCopy[(rowInBox * boxWidth + colInBox) * 4 + 1] = cuParams.colorCopy[(rowOnScreen * width + colOnScreen) * 4 + 1];
     sharedColorCopy[(rowInBox * boxWidth + colInBox) * 4 + 2] = cuParams.colorCopy[(rowOnScreen * width + colOnScreen) * 4 + 2];
     sharedColorCopy[(rowInBox * boxWidth + colInBox) * 4 + 3] = cuParams.colorCopy[(rowOnScreen * width + colOnScreen) * 4 + 3];
    __syncthreads();

    int prevRowOnScreen = round(rowOnScreen - TIME_STEP * cuParams.VY[rowOnScreen * width + colOnScreen]);
    int prevColOnScreen = round(colOnScreen - TIME_STEP * cuParams.VX[rowOnScreen * width + colOnScreen]);

    if (prevColOnScreen < cells_per_side && prevRowOnScreen < cells_per_side 
            && prevColOnScreen >= 0 && prevRowOnScreen >= 0) {
        if (isInBox(prevRowOnScreen, prevColOnScreen, blockDim.x, blockDim.y, blockIdx.x, blockIdx.y)) {
            int r = prevRowOnScreen % blockDim.y;
            int c = prevColOnScreen % blockDim.x;
            cuParams.color[(rowOnScreen * width + colOnScreen) * 4 + 0] = sharedColorCopy[(r * boxWidth + c) * 4 + 0]; 
            cuParams.color[(rowOnScreen * width + colOnScreen) * 4 + 1] = sharedColorCopy[(r * boxWidth + c) * 4 + 1];
            cuParams.color[(rowOnScreen * width + colOnScreen) * 4 + 2] = sharedColorCopy[(r * boxWidth + c) * 4 + 2];
            cuParams.color[(rowOnScreen * width + colOnScreen) * 4 + 3] = sharedColorCopy[(r * boxWidth + c) * 4 + 3];
        } else {
            cuParams.color[(rowOnScreen * width + colOnScreen) * 4 + 0] = 
                cuParams.colorCopy[(prevRowOnScreen * width + prevColOnScreen) * 4 + 0];
            cuParams.color[(rowOnScreen * width + colOnScreen) * 4 + 1] = 
                cuParams.colorCopy[(prevRowOnScreen * width + prevColOnScreen) * 4 + 1];
            cuParams.color[(rowOnScreen * width + colOnScreen) * 4 + 2] = 
                cuParams.colorCopy[(prevRowOnScreen * width + prevColOnScreen) * 4 + 2];
            cuParams.color[(rowOnScreen * width + colOnScreen) * 4 + 3] = 
                cuParams.colorCopy[(prevRowOnScreen * width + prevColOnScreen) * 4 + 3];
        }
   } 
}

//kernelDrawColor
__global__ void kernelDrawColor(int mplsSize) {
    int col = blockIdx.x * blockDim.x + threadIdx.x;
    int row = blockIdx.y * blockDim.y + threadIdx.y; 
    int width = cuParams.width;
    int height = cuParams.height;

    if (col >= width || row >= height) return;
    if (row * width + col >= width * height) return; 

    int index = 4 * (row * width + col);

    double vx = cuParams.VX[row * width + col];
    double vy = cuParams.VY[row * width + col];
    double v = sqrt(vx * vx + vy * vy);

    if (abs(v) < 0.00001) {
        // make the color go away faster
        cuParams.color[index] *= 0.9;
        cuParams.color[index + 1] *= 0.9;
        cuParams.color[index + 2] *= 0.9;
        cuParams.color[index + 3] = 1.0;
    } 
    cuParams.color[index] *= 0.9494; 
    cuParams.color[index + 1] *= 0.9494; 
    cuParams.color[index + 2] *= 0.9696; 

    if (mplsSize > 0) {
        double projection;
        double vx;
        double vy;
        double l = distanceToNearestMouseSegment(col, row, 
                &projection, &vx, &vy);

        float taperFactor = 0.6;
        double projectedFraction = 1.0 - fminf(1.0, 
                fmaxf(projection, 0.0)) * taperFactor;
        double R = 12; //0.025; // the bigger, the more stuff gets cdColored
        double m = exp(-l/R); //drag coefficient
        double speed = sqrt(vx * vx + vy * vy);

        //printf("l is %f, m is %f, projection is %f\n", l, m, projection);

        double x = fminf(1.0, fmaxf(fabs((speed * speed * 0.02 - 
                    projection * 5.0) * projectedFraction), 0.0));

        double r = (2.4 / 60.0) * x + (0.2 /30.0) * (1-x) + (1.0 * pow(x, 9.0));
        double g = (0.0 / 60.0) * x + (51.8 / 30.0) * (1-x) + (1.0 * pow(x, 9.0));
        double b = (5.9 / 60.0) * x + (100.0 / 30.0) * (1-x) + (1.0 * pow(x, 9.0));

        cuParams.color[index] += m * r;
        cuParams.color[index + 1] += m * g;
        cuParams.color[index + 2] += m * b;
        cuParams.color[index + 3] = 1.0;
    }

    cuParams.imageData[index] = cuParams.color[index];
    cuParams.imageData[index + 1] = cuParams.color[index + 1];
    cuParams.imageData[index + 2] = cuParams.color[index + 2];
    cuParams.imageData[index + 3] = cuParams.color[index + 3];

}


//////////////////////////////////////////////////////////////////////////
///////////////////////////HOST CODE BELOW////////////////////////////////
//////////////////////////////////////////////////////////////////////////

CudaRenderer::CudaRenderer() {
    image = NULL;

    VX = NULL;
    VY = NULL;
    color = NULL;
    colorCopy = NULL;
    pressures = NULL;
    pressuresCopy = NULL;
    VXCopy = NULL;
    VYCopy = NULL;
    divergence = NULL;
    vorticity = NULL;

    mpls = NULL;

    cdVX = NULL;
    cdVY = NULL;
    cdColor = NULL;
    cdColorCopy = NULL;
    cdPressures = NULL;
    cdPressuresCopy = NULL;
    cdVXCopy = NULL;
    cdVYCopy = NULL;
    cdDivergence = NULL;
    cdVorticity = NULL;
    cdImageData = NULL;

    cdMpls = NULL;
}

CudaRenderer::~CudaRenderer() {

    if (image) delete image;

    if (VX) {
        delete VX;
        delete VY;
        delete pressures;
        delete pressuresCopy;
        delete VXCopy;
        delete VYCopy;
        delete divergence;
        delete vorticity;
        delete color;
        delete colorCopy;
        delete mpls;
    }

    if (cdVX) {
        cudaFree(cdVX);
        cudaFree(cdVY);
        cudaFree(cdPressures);
        cudaFree(cdPressuresCopy);
        cudaFree(cdVXCopy);
        cudaFree(cdVYCopy);
        cudaFree(cdDivergence);
        cudaFree(cdVorticity);
        cudaFree(cdColor);
        cudaFree(cdColorCopy);
        cudaFree(cdImageData);
        cudaFree(cdMpls);
    }
}

const Image*
CudaRenderer::getImage() {
    printf("Copying image data from device\n");

    cudaMemcpy(image->data, cdImageData, 
            4 * sizeof(float) * image->width * image->height,
            cudaMemcpyDeviceToHost);

    return image;
}


void
CudaRenderer::setup() {
   cells_per_side = image->width / CELL_DIM - 1;

   cudaMalloc(&cdVX, sizeof(float) * (cells_per_side + 1) * (cells_per_side + 1));
   cudaMalloc(&cdVY, sizeof(float) * (cells_per_side + 1) * (cells_per_side + 1));
   cudaMalloc(&cdPressures, sizeof(float) * (cells_per_side + 1) * (cells_per_side + 1));
   cudaMalloc(&cdPressuresCopy, sizeof(float) * (cells_per_side + 1) * (cells_per_side + 1));
   cudaMalloc(&cdVXCopy, sizeof(float) * (cells_per_side + 1) * (cells_per_side + 1));
   cudaMalloc(&cdVYCopy, sizeof(float) * (cells_per_side + 1) * (cells_per_side + 1));
   cudaMalloc(&cdDivergence, sizeof(float) * (cells_per_side + 1) * (cells_per_side + 1));
   cudaMalloc(&cdVorticity, sizeof(float) * (cells_per_side + 1) * (cells_per_side + 1));
   cudaMalloc(&cdColor, 4 * sizeof(float) * (cells_per_side + 1) * (cells_per_side + 1));
   cudaMalloc(&cdColorCopy, 4 * sizeof(float) * (cells_per_side + 1) * (cells_per_side + 1));
   cudaMalloc(&cdImageData, 4 * sizeof(float) * image->width * image->height);
   cudaMalloc(&cdMpls, 400 * sizeof(float) * image->width * image->height);

   cudaMemset(cdVX, 0, sizeof(float) * (cells_per_side + 1) * (cells_per_side + 1));
   cudaMemset(cdVY, 0, sizeof(float) * (cells_per_side + 1) * (cells_per_side + 1));
   cudaMemset(cdPressures, 0, sizeof(float) * (cells_per_side + 1) * (cells_per_side + 1));
   cudaMemset(cdPressuresCopy, 0, sizeof(float) * (cells_per_side + 1) * (cells_per_side + 1));
   cudaMemset(cdVXCopy, 0, sizeof(float) * (cells_per_side + 1) * (cells_per_side + 1));
   cudaMemset(cdVYCopy, 0, sizeof(float) * (cells_per_side + 1) * (cells_per_side + 1));
   cudaMemset(cdDivergence, 0, sizeof(float) * (cells_per_side + 1) * (cells_per_side + 1));
   cudaMemset(cdVorticity, 0, sizeof(float) * (cells_per_side + 1) * (cells_per_side + 1));
   cudaMemset(cdColor, 0, 4 * sizeof(float) * (cells_per_side + 1) * (cells_per_side + 1));
   cudaMemset(cdColorCopy, 0, 4 * sizeof(float) * (cells_per_side + 1) * (cells_per_side + 1));

    GlobalConstants params;
    params.cells_per_side = cells_per_side;
    params.width = image->width;
    params.height = image->height;
    params.VX = cdVX;
    params.VY = cdVY;
    params.pressures = cdPressures;
    params.pressuresCopy = cdPressuresCopy;
    params.VXCopy = cdVXCopy;
    params.VYCopy = cdVYCopy;
    params.divergence = cdDivergence;
    params.vorticity = cdVorticity;
    params.color = cdColor;
    params.colorCopy = cdColorCopy;
    params.imageData = cdImageData;
    params.mpls = cdMpls;

    cudaMemcpyToSymbol(cuParams, &params, sizeof(GlobalConstants));
}

// Called after clear, before render
void CudaRenderer::setNewQuantities(std::vector<std::pair<int, int> > mpls) {

    mplsSize = mpls.size();
    if (mplsSize < 1) {
        // if mpls.size is 0, then call kernel that decreases VX,VY by 0.999
        dim3 blockDim(BLOCKSIDE,BLOCKSIDE,1);
        dim3 gridDim(
                (image->width + blockDim.x - 1) / blockDim.x,
                (image->height + blockDim.y - 1) / blockDim.y);
        kernelFadeVelocities<<<gridDim, blockDim>>>();
        cudaDeviceSynchronize();

    } else {
        int* mplsArray = new int[mplsSize * 2];
        int count = 0;
        for (std::vector<std::pair<int,int> >::iterator it = mpls.begin() 
                ; it != mpls.end(); ++it) {
            std::pair<int,int> c = *it;
            mplsArray[count] = c.first;
            mplsArray[count + 1] = c.second;
            count += 2;
        }
        cudaMemset(cdMpls, 0, 400 * sizeof(int));
        cudaMemcpy(cdMpls, mplsArray, (mplsSize * 2) * sizeof(int), 
                cudaMemcpyHostToDevice);

        dim3 blockDim(BLOCKSIDE,BLOCKSIDE,1);
        dim3 gridDim(
                (image->width + blockDim.x - 1) / blockDim.x,
                (image->height + blockDim.y - 1) / blockDim.y);
        kernelSetNewVelocities<<<gridDim, blockDim>>>();
        cudaDeviceSynchronize();
    }
}

// allocOutputImage --
//
// Allocate buffer the renderer will render into.  Check status of
// image first to avoid memory leak.
void
CudaRenderer::allocOutputImage(int width, int height) {

    if (image)
        delete image;
    image = new Image(width, height);
}

// clearImage --
//
// Clear's the renderer's target image.  
void
CudaRenderer::clearImage() {
    dim3 blockDim(BLOCKSIDE,BLOCKSIDE,1);
    dim3 gridDim(
            (image->width + blockDim.x - 1) / blockDim.x,
            (image->height + blockDim.y - 1) / blockDim.y);
    kernelClearImage<<<gridDim, blockDim>>>(1.f,1.f,1.f,1.f);
    cudaDeviceSynchronize();
}

void
CudaRenderer::render() {
    dim3 blockDim(BLOCKSIDE,BLOCKSIDE,1);
    dim3 gridDim(
            (image->width + blockDim.x - 1) / blockDim.x,
            (image->height + blockDim.y - 1) / blockDim.y);
    kernelCopyVelocities<<<gridDim, blockDim>>>();
    cudaDeviceSynchronize(); 
    kernelAdvectVelocityForward<<<gridDim, blockDim>>>();
    //cudaDeviceSynchronize();
    kernelAdvectVelocityBackward<<<gridDim, blockDim>>>();
    cudaDeviceSynchronize();
    
    kernelApplyVorticity<<<gridDim, blockDim>>>();
    cudaDeviceSynchronize();
    kernelApplyVorticityForce<<<gridDim, blockDim>>>();
    cudaDeviceSynchronize();

    kernelApplyDivergence<<<gridDim, blockDim>>>();
    cudaDeviceSynchronize();

    kernelCopyPressures<<<gridDim, blockDim>>>();
    cudaDeviceSynchronize();
    kernelPressureSolve<<<gridDim, blockDim>>>();
    cudaDeviceSynchronize();

    kernelPressureGradient<<<gridDim, blockDim>>>();
    cudaDeviceSynchronize();
   
    //DRAW STUFF
    kernelDrawColor<<<gridDim, blockDim>>>(mplsSize);
    //cudaDeviceSynchronize();
 
    kernelCopyColor<<<gridDim,blockDim>>>();
    cudaDeviceSynchronize(); 
    kernelAdvectColorForward<<<gridDim, blockDim>>>();
    cudaDeviceSynchronize();
    kernelAdvectColorBackward<<<gridDim, blockDim>>>();
    cudaDeviceSynchronize();
}

