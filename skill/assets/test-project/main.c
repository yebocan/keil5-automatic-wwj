/**
  ******************************************************************************
  * @file    main.c
  * @brief   测试例程：用于验证 keil5-automatic-wwj 技能的编译/调试链路。
  *
  * 本文件刻意保持极小：不依赖 STM32 标准外设库，只使用 CMSIS 的
  * stm32f10x.h，因此可以独立编译，适合作为技能自检的固定夹具。
  *
  * 变量 global_counter / global_flag 供调试层（断点、单步、读变量）使用。
  ******************************************************************************
  */

#include "stm32f10x.h"

/* ---- 供调试层观察的全局变量 ---- */
volatile int  global_counter = 0;
volatile int  global_flag    = 0;
volatile int  global_array[4] = { 11, 22, 33, 44 };

/* ---- 简单的延时循环（不需要 SysTick 配置） ---- */
static void delay_loop(volatile int n)
{
    while (n-- > 0)
    {
        __NOP();
    }
}

/**
  * @brief  累加测试函数：每次调用把 global_counter 增加 step。
  *         调试时可在本函数下断点，观察参数与返回值。
  */
int accumulate(int step)
{
    int before = global_counter;      /* 断点观察点 1 */
    global_counter += step;           /* 断点观察点 2 */
    if (global_counter > 100)
    {
        global_flag = 1;              /* 断点观察点 3 */
    }
    return before;
}

int main(void)
{
    int i;

    /* 初始化数组，方便调试时查看内存 */
    for (i = 0; i < 4; i++)
    {
        global_array[i] = i * 100;
    }

    while (1)
    {
        accumulate(10);
        delay_loop(1000);
        global_flag = 0;
    }
}
