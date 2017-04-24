#include <algorithm>
#include <math.h>
#include <stdio.h>
#include <vector>
#include <unistd.h>
#include <math.h>
#include "refRenderer.h"
#include "image.h"
#include "util.h"

#define CELL_DIM 1
#define TIME_STEP 1

RefRenderer::RefRenderer() {
    image = NULL;
    mousePressedLocation = NULL;
    velocitiesX = NULL;
    velocitiesY = NULL;
    color = NULL;
    colorCopy = NULL;
    pressures = NULL;
    advectionCopy = NULL;
}

RefRenderer::~RefRenderer() {

    if (image) delete image;
    if (mousePressedLocation) delete mousePressedLocation;

    if (velocitiesX) {
        for (int i = 0; i < cells_per_side + 1; i++) {
            if (velocitiesX[i]) delete velocitiesX[i];

        }
        delete velocitiesX;
    }
    if (velocitiesY) {
        for (int i = 0; i < cells_per_side + 1; i++) {
            if (velocitiesY[i]) delete velocitiesY[i];
        }
        delete velocitiesY;
    }

    if (pressures) {
        for (int i = 0; i < cells_per_side + 1; i++) {
            if (pressures[i]) delete pressures[i];
        }
        delete pressures;
    }
    if (advectionCopy) {
        for (int i = 0; i < cells_per_side + 1; i++) {
            if (advectionCopy[i]) delete advectionCopy[i];
        }
        delete advectionCopy;
    }

    if (color) {
        for (int i = 0; i < cells_per_side + 1; i++) {
            if (color[i]) {
                for (int j = 0; j < cells_per_side; j++) {
                    if (color[i][j]) delete color[i][j];
                }
            }
            delete color[i];
        }
        delete color;
    }
    if (colorCopy) {
        for (int i = 0; i < cells_per_side + 1; i++) {
            if (colorCopy[i]) {
                for (int j = 0; j < cells_per_side; j++) {
                    if (colorCopy[i][j]) delete colorCopy[i][j];
                }
            }
            delete colorCopy[i];
        }
        delete colorCopy;
    }

}

const Image*
RefRenderer::getImage() {
    return image;
}

void
RefRenderer::setup() {
   cells_per_side = image->width / CELL_DIM;
   velocitiesX = new float*[cells_per_side + 1];
   for (int i = 0; i < cells_per_side + 1; i++) {
    velocitiesX[i] = new float[cells_per_side + 1];
    for (int j = 0; j < cells_per_side + 1; j++) { 
        if (j < cells_per_side / 2) { 
            velocitiesX[i][j] = 0.0;
        } else {
            velocitiesX[i][j] = 0.0;
        }
    }
   }

   velocitiesY = new float*[cells_per_side + 1];
   for (int i = 0; i < cells_per_side + 1; i++) {
    velocitiesY[i] = new float[cells_per_side + 1];
    for (int j = 0; j < cells_per_side + 1; j++) {
        if (j < cells_per_side / 2) {
            velocitiesY[i][j] = 0.0;
        } else {
            velocitiesY[i][j] = 0.0;
        }
    }
   }

   pressures = new float*[cells_per_side + 1];
   for (int i = 0; i < cells_per_side + 1; i++) {
    pressures[i] = new float[cells_per_side + 1];
    for (int j = 0; j < cells_per_side + 1; j++) {
        if (j < cells_per_side / 2) {
            pressures[i][j] = 0.0;
        } else {
            pressures[i][j] = 0.0;
        }
    }
   }
    
   advectionCopy = new float*[cells_per_side + 1];
   for (int i = 0; i < cells_per_side + 1; i++) {
    advectionCopy[i] = new float[cells_per_side + 1];
   }

   color = new float**[cells_per_side + 1];
   for (int i = 0; i < cells_per_side + 1; i++) {
    color[i] = new float*[(cells_per_side + 1)];
    for (int j = 0; j < cells_per_side + 1; j++) {
        color[i][j] = new float[4];
        /*if (i % 2 == 0 && j % 2 == 0) {
            color[i][j][0] = 0.4666;
            color[i][j][1] = 0.7882;
            color[i][j][2] = 0.2666;
            color[i][j][3] = 1.0;
        } else if (i % 2 == 0 && j % 2 == 1){
            color[i][j][0] = 0.1798;
            color[i][j][1] = 0.457;
            color[i][j][2] = 0.90630;
            color[i][j][3] = 1.0;
        } else if (i % 2 == 1 && j % 2 == 1) {
            color[i][j][0] = 0.4666;
            color[i][j][1] = 0.7882;
            color[i][j][2] = 0.2666;
            color[i][j][3] = 1.0; 
        } else {
            color[i][j][0] = 0.1798;
            color[i][j][1] = 0.457;
            color[i][j][2] = 0.90630;
            color[i][j][3] = 1.0;
        }*/
            color[i][j][0] = 0;
            color[i][j][1] = 0.0392;
            color[i][j][2] = 0.1098;
            color[i][j][3] = 1.0;
            /*if (220 < i && i < 230 && 220 < j && j < 230) {
                color[i][j][0] = 1.0;
                color[i][j][1] = 0.4;
                color[i][j][2] = 0.2;
                color[i][j][3] = 0.5;

            }*/


    }
   }
   colorCopy = new float**[cells_per_side + 1];
   for (int i = 0; i < cells_per_side + 1; i++) {
    colorCopy[i] = new float*[(cells_per_side + 1)];
    for (int j = 0; j < cells_per_side + 1; j++) {
        colorCopy[i][j] = new float[4];
        /*if (i % 2 == 0 && j % 2 == 0) {
            color[i][j][0] = 0.4666;
            color[i][j][1] = 0.7882;
            color[i][j][2] = 0.2666;
            color[i][j][3] = 1.0;
        } else if (i % 2 == 0 && j % 2 == 1){
            color[i][j][0] = 0.1798;
            color[i][j][1] = 0.457;
            color[i][j][2] = 0.90630;
            color[i][j][3] = 1.0;
        } else if (i % 2 == 1 && j % 2 == 1) {
            color[i][j][0] = 0.4666;
            color[i][j][1] = 0.7882;
            color[i][j][2] = 0.2666;
            color[i][j][3] = 1.0; 
        } else {
            color[i][j][0] = 0.1798;
            color[i][j][1] = 0.457;
            color[i][j][2] = 0.90630;
            color[i][j][3] = 1.0;
        }*/

            /*color[i][j][0] = 0;
            color[i][j][1] = 0.0392;
            color[i][j][2] = 0.1098;
            color[i][j][3] = 1.0;*/
            /*if (220 < i && i < 230 && 220 < j && j < 230) {
                color[i][j][0] = 1.0;
                color[i][j][1] = 0.4;
                color[i][j][2] = 0.2;
                color[i][j][3] = 0.5;

            }*/
    }
   }


}

void RefRenderer::setMousePressedLocation(int* mpl) {
    //mousePressedLocation = mpl;
    for (int i = 0; i < image->height * image-> width; i++) {
        //mousePressedLocation[i] = mpl[i];
        if (mpl[i] == 1) {
            int grid_row = (i / image->width) / (CELL_DIM);
            int grid_col = (i % image->width) / (CELL_DIM);
            printf("setting grid %d,%d to be white!!!\n", grid_row, grid_col);
            color[grid_row][grid_col][0] = 1.0;
            color[grid_row][grid_col][1] = 1.0;
            color[grid_row][grid_col][2] = 1.0;
            color[grid_row][grid_col][3] = 1.0;
            velocitiesY[grid_row][grid_col] = 4.0;
        }
    }
}

void RefRenderer::setNewVelocities(double* vxs, double* vys) {
    for (int i = 0; i < image->height * image-> width; i++) {
        if (vxs[i] != 0.0 || vys[i] != 0.0) {
            int grid_row = (i / image->width) / (CELL_DIM);
            int grid_col = (i % image->width) / (CELL_DIM);
            velocitiesX[grid_row][grid_col] = vxs[i];
            velocitiesY[grid_row][grid_col] = vys[i];
            printf("setting velocity of row %d col %d to [%f,%f]\n", grid_row, 
                    grid_col, vxs[i], vys[i]);
        }
    }

}

// allocOutputImage --
//
// Allocate buffer the renderer will render into.  Check status of
// image first to avoid memory leak.
void
RefRenderer::allocOutputImage(int width, int height) {

    if (image)
        delete image;
    image = new Image(width, height);
}

// clearImage --
//
// Clear's the renderer's target image.  
void
RefRenderer::clearImage() {
    image->clear(1.f, 1.f, 1.f, 1.f);
}

void RefRenderer::advectColorBackward() {
    //Advecting the values in color
    for (int row = 0; row < cells_per_side; row++) {
        for (int col = 0; col < cells_per_side; col++) {
           int pixelRow = row * CELL_DIM;// + CELL_DIM/2;
           int pixelCol = col * CELL_DIM;// + CELL_DIM/2;
           int prevPixelRow = round(pixelRow - TIME_STEP * velocitiesY[row][col] * CELL_DIM);
           int prevPixelCol = round(pixelCol - TIME_STEP * velocitiesX[row][col] * CELL_DIM);
           int prevCellCol = prevPixelCol / CELL_DIM;
           int prevCellRow = prevPixelRow / CELL_DIM;

           //printf("PIXEL (%d,%d) has prev (%d,%d)\n",pixelRow,pixelCol,prevPixelRow,prevPixelCol);
           //printf("CELL (%d,%d) has prev (%d,%d)\n", row,col,prevCellRow,prevCellCol);
           if (prevCellCol < cells_per_side && prevCellRow < cells_per_side 
                   && prevCellCol >= 0 && prevCellRow >= 0) {
                color[row][col][0] = colorCopy[prevCellRow][prevCellCol][0];
                color[row][col][1] = colorCopy[prevCellRow][prevCellCol][1];
                color[row][col][2] = colorCopy[prevCellRow][prevCellCol][2];
                color[row][col][3] = colorCopy[prevCellRow][prevCellCol][3];
           } else {
                /*color[row][col][0] = 0.0;
                color[row][col][1] = 0.0;
                color[row][col][2] = 0.0;
                color[row][col][3] = 0.0;*/   
           }
        }
    }
}

void RefRenderer::advectColorForward() {
    //Advecting the values in color
    for (int row = 0; row < cells_per_side; row++) {
        for (int col = 0; col < cells_per_side; col++) {
           int pixelRow = row * CELL_DIM;// + CELL_DIM/2;
           int pixelCol = col * CELL_DIM;// + CELL_DIM/2;
           int nextPixelRow = round(pixelRow + TIME_STEP * velocitiesY[row][col] * CELL_DIM);
           int nextPixelCol = round(pixelCol + TIME_STEP * velocitiesX[row][col] * CELL_DIM);
           int nextCellCol = nextPixelCol / CELL_DIM;
           int nextCellRow = nextPixelRow / CELL_DIM;

           int prevPixelRow = round(pixelRow - TIME_STEP * velocitiesY[row][col] * CELL_DIM);
           int prevPixelCol = round(pixelCol - TIME_STEP * velocitiesX[row][col] * CELL_DIM);
           int prevCellCol = prevPixelCol / CELL_DIM;
           int prevCellRow = prevPixelRow / CELL_DIM;

           if (nextCellRow != row || prevCellRow != row)    
            printf("(%d,%d): forward is (%d,%d), backward is (%d,%d)\n", row, col, nextCellRow, nextCellCol, prevCellRow,prevCellCol);

           if ((nextPixelRow != pixelRow || nextPixelCol != pixelCol) &&
                   nextCellCol < cells_per_side && nextCellRow < cells_per_side 
                   && nextCellCol >= 0 && nextCellRow >= 0) {
                //printf("advecting to row %d col %d from row %d col %d\n",nextPixelRow,
                //        nextPixelCol, pixelRow, pixelCol);
           }
           //printf("PIXEL (%d,%d) has prev (%d,%d)\n",pixelRow,pixelCol,prevPixelRow,prevPixelCol);
           //printf("CELL (%d,%d) has prev (%d,%d)\n", row,col,prevCellRow,prevCellCol);
           if (nextCellCol < cells_per_side && nextCellRow < cells_per_side 
                   && nextCellCol >= 0 && nextCellRow >= 0) {
                color[nextCellRow][nextCellCol][0] = colorCopy[row][col][0];
                color[nextCellRow][nextCellCol][1] = colorCopy[row][col][1];
                color[nextCellRow][nextCellCol][2] = colorCopy[row][col][2];
                color[nextCellRow][nextCellCol][3] = colorCopy[row][col][3];
           } else {
                /*color[nextCellRow][nextCellCol][0] = 0.0;
                color[nextCellRow][nextCellCol][1] = 0.0;
                color[nextCellRow][nextCellCol][2] = 0.0;
                color[nextCellRow][nextCellCol][3] = 0.0;   */
           }
        }
    }
}

void RefRenderer::advectBackward(float** quantity) {
    //Advecting the values
    for (int row = 0; row < cells_per_side; row++) {
        for (int col = 0; col < cells_per_side; col++) {
           int pixelRow = row * CELL_DIM;// + CELL_DIM/2;
           int pixelCol = col * CELL_DIM;// + CELL_DIM/2;
           int prevPixelRow = round(pixelRow - TIME_STEP * velocitiesY[row][col] * CELL_DIM);
           int prevPixelCol = round(pixelCol - TIME_STEP * velocitiesX[row][col] * CELL_DIM);
           int prevCellCol = prevPixelCol / CELL_DIM;
           int prevCellRow = prevPixelRow / CELL_DIM;

           if (prevCellCol < cells_per_side && prevCellRow < cells_per_side 
                   && prevCellCol >= 0 && prevCellRow >= 0) {
                quantity[row][col] = advectionCopy[prevCellRow][prevCellCol];
           } else {
                //quantity[row][col] = 0.0;
           }
        }
    }
}

void RefRenderer::advectForward(float** quantity) {
    //Advecting the values
    for (int row = 0; row < cells_per_side; row++) {
        for (int col = 0; col < cells_per_side; col++) {
           int pixelRow = row * CELL_DIM;// + CELL_DIM/2;
           int pixelCol = col * CELL_DIM;// + CELL_DIM/2;
           int nextPixelRow = round(pixelRow + TIME_STEP * velocitiesY[row][col] * CELL_DIM);
           int nextPixelCol = round(pixelCol + TIME_STEP * velocitiesX[row][col] * CELL_DIM);
           int nextCellCol = nextPixelCol / CELL_DIM;
           int nextCellRow = nextPixelRow / CELL_DIM;

           if (nextCellCol < cells_per_side && nextCellRow < cells_per_side 
                   && nextCellCol >= 0 && nextCellRow >= 0) {
                quantity[nextCellRow][nextCellCol] = advectionCopy[row][col];
           } else {
                //quantity[nextCellRow][nextCellCol] = 0.0;
           }
        }
    }
}
void
RefRenderer::advectColor() {
    for (int i = 0; i < cells_per_side + 1; i++) {
        for (int j = 0; j < cells_per_side + 1; j++) {
            for (int k = 0; k < 4; k++) {
                colorCopy[i][j][k] = color[i][j][k];
            }
        }
    }
    advectColorForward();
    advectColorBackward();
}

void
RefRenderer::advectQuantity(float** quantity) {
    for (int i = 0; i < cells_per_side + 1; i++) {
        for (int j = 0; j < cells_per_side + 1; j++) {
            advectionCopy[i][j] = quantity[i][j];
        }
    }
    advectForward(quantity);
    advectBackward(quantity);
}
void
RefRenderer::render() {
    //usleep(TIME_STEP*1000000);

    // Advect

    //advectColor();
    //advectQuantity(pressures);
    advectQuantity(velocitiesX);
    advectQuantity(velocitiesY);
        
    // Draw
    for (int i = 0; i < 4*image->width*image->height; i+=4) {
            int grid_row = ((i/4) / image->width) / (CELL_DIM);
            int grid_col = ((i/4) % image->width) / (CELL_DIM);
            /*image->data[i] = color[grid_row][grid_col][0];
            image->data[i+1] = color[grid_row][grid_col][1]; 
            image->data[i+2] = color[grid_row][grid_col][2];
            image->data[i+3] = color[grid_row][grid_col][3];*/
            if (velocitiesX[grid_row][grid_col] != 0.0 || 
                    velocitiesY[grid_row][grid_col] != 0.0) {
                image->data[i] = 1.0;
                image->data[i+1] = 1.0;
                image->data[i+2] = 1.0;
                image->data[i+3] = 1.0;
            } /*else if (velocitiesY[grid_row][grid_col] > 0.0) {
                image->data[i] = 0.8;
                image->data[i+1] = 0.8;
                image->data[i+2] = 1.0;
                image->data[i+3] = 1.0;

            }*/ else {
                image->data[i] = 0.0;
                image->data[i+1] = 0.0392;
                image->data[i+2] = 0.1098;
                image->data[i+3] = 1.0;

            }
    } 
    // Make mouse clicked locations turn white
    /* for (int i = 0; i < 4*image->width*image->height; i+=4) {
        if (mousePressedLocation[i / 4]) {
            image->data[i] = 1.0;
            image->data[i+1] = 1.0;
            image->data[i+2] = 1.0;
            image->data[i+3] = 1.0;
        } else {
            image->data[i] = 0.1798;
            image->data[i+1] = 0.457;
            image->data[i+2] = 0.9063;
            image->data[i+3] = 0.5;
        }
    }*/
}

